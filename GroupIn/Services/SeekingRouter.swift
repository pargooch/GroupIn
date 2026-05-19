//
//  SeekingRouter.swift
//  GroupIn
//
//  Picks the best `SeekingChannel` for each engaged peer based on
//  shared `TransportCapability` bits. Drives one channel per peer at
//  a time and forwards its ranging samples upward under one stable
//  stream — consumers (AppState → CompassEngine) attach once and
//  don't care which channel is currently active.
//
//  Mirrors `PayloadTransportRouter` for the chat / event-log tier.
//

import Foundation

@MainActor
final class SeekingRouter {

    /// Unified ranging stream. Every active child's samples flow into
    /// this continuation; selection / handoff happens beneath it.
    let rangingUpdates: AsyncStream<RangingSample>
    private let rangingContinuation: AsyncStream<RangingSample>.Continuation

    /// Live diagnostics — the currently-engaged channel per peer.
    let diagnostics: AsyncStream<SeekingDiagnostics>
    private let diagnosticsContinuation: AsyncStream<SeekingDiagnostics>.Continuation
    private var currentDiagnostics = SeekingDiagnostics.empty

    // MARK: - Channels

    private let uwb: SeekingChannel
    private let wifiAware: SeekingChannel
    private let ble: SeekingChannel

    /// Which channel is currently engaged for each peer. Drives the
    /// diagnostic strip and the per-channel disengage call when a
    /// reselection happens.
    private var engagedChannelByMember: [UUID: SeekingChannelKind] = [:]
    private var forwarderTasks: [Task<Void, Never>] = []

    /// Cached capability lookups. The router doesn't probe peers
    /// itself — AppState calls `updateCapability(...)` whenever a
    /// peer's presence packet is decoded or the local capability is
    /// computed at launch.
    private var localCapability: TransportCapability = .none
    private var peerCapabilities: [UUID: TransportCapability] = [:]

    // MARK: - Init

    init(uwb: SeekingChannel, wifiAware: SeekingChannel, ble: SeekingChannel) {
        self.uwb = uwb
        self.wifiAware = wifiAware
        self.ble = ble

        let (rangingStream, rangingCont) = AsyncStream.makeStream(of: RangingSample.self)
        self.rangingUpdates = rangingStream
        self.rangingContinuation = rangingCont

        let (diagStream, diagCont) = AsyncStream.makeStream(of: SeekingDiagnostics.self)
        self.diagnostics = diagStream
        self.diagnosticsContinuation = diagCont

        startForwarders()
    }

    // MARK: - Capability state

    func setLocalCapability(_ capability: TransportCapability) {
        localCapability = capability
    }

    func setPeerCapability(_ capability: TransportCapability, for memberID: UUID) {
        peerCapabilities[memberID] = capability
        // If we're already engaged for this peer, the new capability
        // may have unlocked a better channel — reselect.
        if engagedChannelByMember[memberID] != nil {
            reselectChannel(for: memberID)
        }
    }

    // MARK: - Engagement

    func engage(targetMemberID memberID: UUID) {
        reselectChannel(for: memberID)
    }

    func disengage(targetMemberID memberID: UUID) {
        if let kind = engagedChannelByMember.removeValue(forKey: memberID) {
            channel(for: kind).disengage(targetMemberID: memberID)
        }
        currentDiagnostics.sampleCountByMember.removeValue(forKey: memberID)
        currentDiagnostics.lastSampleByMember.removeValue(forKey: memberID)
        currentDiagnostics.activeChannel = engagedChannelByMember.values.first
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func stop() {
        for member in engagedChannelByMember.keys {
            disengage(targetMemberID: member)
        }
        uwb.stop()
        wifiAware.stop()
        ble.stop()
        currentDiagnostics = .empty
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    // MARK: - Selection

    /// Pick the best channel for `memberID` and engage/disengage as
    /// needed. Called on initial engage, on capability updates, and
    /// (later) on availability flips when channels drop out.
    private func reselectChannel(for memberID: UUID) {
        let peerCap = peerCapabilities[memberID] ?? .none
        let pick = SeekingChannelSelector.bestChannel(
            local: localCapability, peer: peerCap
        )
        let currently = engagedChannelByMember[memberID]
        guard pick != currently else {
            // Already on the right channel — ensure it's engaged.
            channel(for: pick).engage(targetMemberID: memberID)
            return
        }
        // Switch: disengage prior channel (if any), engage new one.
        if let currently {
            channel(for: currently).disengage(targetMemberID: memberID)
        }
        channel(for: pick).engage(targetMemberID: memberID)
        engagedChannelByMember[memberID] = pick
        currentDiagnostics.activeChannel = pick
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    private func channel(for kind: SeekingChannelKind) -> SeekingChannel {
        switch kind {
        case .uwb: return uwb
        case .wifiAwareRanging: return wifiAware
        case .bleRanging: return ble
        }
    }

    // MARK: - Forwarders

    /// Pump each child channel's `rangingUpdates` into the router's
    /// unified stream. Per-channel stats also feed `currentDiagnostics`
    /// so the indoor strip can show which channel is producing.
    private func startForwarders() {
        let channels: [SeekingChannel] = [uwb, wifiAware, ble]
        for ch in channels {
            let task = Task { @MainActor [weak self] in
                for await sample in ch.rangingUpdates {
                    guard let self else { return }
                    self.rangingContinuation.yield(sample)
                    self.currentDiagnostics.sampleCountByMember[sample.memberID, default: 0] += 1
                    self.currentDiagnostics.lastSampleByMember[sample.memberID] = sample.timestamp
                    // Light throttle — diagnostics fire at most every
                    // 500ms so the UI doesn't re-render at 5 Hz.
                    self.maybeYieldDiagnostics()
                }
            }
            forwarderTasks.append(task)
        }
    }

    private var lastDiagnosticsYield: Date = .distantPast
    private static let diagnosticsMinInterval: TimeInterval = 0.5

    private func maybeYieldDiagnostics() {
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticsYield) >= Self.diagnosticsMinInterval
        else { return }
        lastDiagnosticsYield = now
        diagnosticsContinuation.yield(currentDiagnostics)
    }
}

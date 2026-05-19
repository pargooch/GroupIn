//
//  SeekingRouter.swift
//  GroupIn
//
//  Routes ranging samples from every supported `SeekingChannel` into a
//  single unified stream that AppState consumes. Engagement is **tiered
//  always-on**: when the user starts seeking a peer, every channel
//  whose capability bits are satisfied on both sides starts producing
//  in parallel. BLE active-RSSI polling is the cheap always-on
//  baseline so the indoor compass works the moment seeking begins;
//  UWB and Wi-Fi Aware engage opportunistically and take over when
//  they have data. The diagnostic strip reports the **highest tier
//  with a recent sample**, computed from the actual sample stream
//  rather than static capability flags — that distinction is what
//  fixes the previous "ch: uwb pinned forever even when UWB isn't
//  delivering" bug.
//
//  Mirrors `PayloadTransportRouter` for the chat / event-log tier in
//  shape, but the lifecycle differs: payload tier is mutually
//  exclusive (one transport per group), seeking tier is concurrent
//  per peer (every supported channel runs).
//

import Foundation

@MainActor
final class SeekingRouter {

    /// Unified ranging stream. Every active child's samples flow into
    /// this continuation; AppState attaches once and routes by
    /// sample.channel + sample fields downstream.
    let rangingUpdates: AsyncStream<RangingSample>
    private let rangingContinuation: AsyncStream<RangingSample>.Continuation

    /// Live diagnostics — which channel is currently producing samples
    /// for each engaged peer.
    let diagnostics: AsyncStream<SeekingDiagnostics>
    private let diagnosticsContinuation: AsyncStream<SeekingDiagnostics>.Continuation
    private var currentDiagnostics = SeekingDiagnostics.empty

    // MARK: - Channels

    private let uwb: SeekingChannel
    private let wifiAware: SeekingChannel
    private let ble: SeekingChannel

    /// Members currently being sought. For each, we engage every
    /// channel whose capabilities are satisfied; we don't pin a
    /// single "active" channel up front.
    private var engagedMembers: Set<UUID> = []
    private var forwarderTasks: [Task<Void, Never>] = []

    /// Cached capability state. AppState calls
    /// `setLocalCapability` at launch and `setPeerCapability` on
    /// every PeerPresence merge.
    private var localCapability: TransportCapability = .none
    private var peerCapabilities: [UUID: TransportCapability] = [:]

    /// Per-channel last-sample time. Used to compute the diagnostic
    /// `activeChannel` — the highest tier whose most recent sample
    /// is fresh enough to count as "currently delivering."
    private var lastSampleByChannel: [SeekingChannelKind: Date] = [:]
    private static let activeChannelFreshness: TimeInterval = 5

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
        // Re-evaluate every engaged member: a freshly-flipped
        // capability bit may add a channel that wasn't engaged before.
        for member in engagedMembers {
            engageAllSupported(for: member)
        }
    }

    func setPeerCapability(_ capability: TransportCapability, for memberID: UUID) {
        peerCapabilities[memberID] = capability
        if engagedMembers.contains(memberID) {
            engageAllSupported(for: memberID)
        }
    }

    // MARK: - Engagement

    func engage(targetMemberID memberID: UUID) {
        engagedMembers.insert(memberID)
        engageAllSupported(for: memberID)
    }

    func disengage(targetMemberID memberID: UUID) {
        guard engagedMembers.remove(memberID) != nil else { return }
        uwb.disengage(targetMemberID: memberID)
        wifiAware.disengage(targetMemberID: memberID)
        ble.disengage(targetMemberID: memberID)
        currentDiagnostics.sampleCountByMember.removeValue(forKey: memberID)
        currentDiagnostics.lastSampleByMember.removeValue(forKey: memberID)
        recomputeActiveChannel()
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func stop() {
        for member in engagedMembers {
            uwb.disengage(targetMemberID: member)
            wifiAware.disengage(targetMemberID: member)
            ble.disengage(targetMemberID: member)
        }
        engagedMembers.removeAll()
        uwb.stop()
        wifiAware.stop()
        ble.stop()
        lastSampleByChannel.removeAll()
        currentDiagnostics = .empty
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    // MARK: - Selection

    /// Engage every channel that has capability support on both sides
    /// for this peer. Idempotent — each channel's own `engage` is
    /// idempotent, so re-running this on a capability change is safe.
    /// BLE is the unconditional baseline so the indoor compass has
    /// continuous RSSI flow even when higher tiers aren't delivering.
    private func engageAllSupported(for memberID: UUID) {
        let peerCap = peerCapabilities[memberID] ?? .none

        if localCapability.uwb && peerCap.uwb {
            uwb.engage(targetMemberID: memberID)
        } else {
            uwb.disengage(targetMemberID: memberID)
        }
        if localCapability.wifiAwareRanging && peerCap.wifiAwareRanging {
            wifiAware.engage(targetMemberID: memberID)
        } else {
            wifiAware.disengage(targetMemberID: memberID)
        }
        // BLE always engages once the peer is in our group's BLE
        // mesh. The channel's own engage is idempotent and the
        // active-RSSI polling Task gets deduped per member.
        ble.engage(targetMemberID: memberID)
    }

    /// The diagnostic strip's `ch:` chip reports the highest tier
    /// that's actually delivering samples — not what the capability
    /// flags say is theoretically supported. UWB hardware can be on
    /// both phones but the NISession still fail to produce direction
    /// vectors (geometry, suspension, etc); in that case the user
    /// should see `ch: ble` to know what's driving the bearing.
    private func recomputeActiveChannel() {
        let now = Date()
        let fresh = Self.activeChannelFreshness
        // Highest-to-lowest tier check.
        if let t = lastSampleByChannel[.uwb], now.timeIntervalSince(t) < fresh {
            currentDiagnostics.activeChannel = .uwb
        } else if let t = lastSampleByChannel[.wifiAwareRanging],
                  now.timeIntervalSince(t) < fresh {
            currentDiagnostics.activeChannel = .wifiAwareRanging
        } else if let t = lastSampleByChannel[.bleRanging],
                  now.timeIntervalSince(t) < fresh {
            currentDiagnostics.activeChannel = .bleRanging
        } else if !engagedMembers.isEmpty {
            // Engaged, but nothing's delivering yet. Show BLE as
            // "what we're trying" since it's the always-on baseline.
            currentDiagnostics.activeChannel = .bleRanging
        } else {
            currentDiagnostics.activeChannel = nil
        }
    }

    // MARK: - Forwarders

    /// Pump each child channel's `rangingUpdates` into the router's
    /// unified stream. Per-channel last-sample timestamps feed the
    /// `activeChannel` diagnostic so the UI can show which tier is
    /// actually driving the compass.
    private func startForwarders() {
        let channels: [SeekingChannel] = [uwb, wifiAware, ble]
        for ch in channels {
            let task = Task { @MainActor [weak self] in
                for await sample in ch.rangingUpdates {
                    guard let self else { return }
                    self.handleForwardedSample(sample)
                }
            }
            forwarderTasks.append(task)
        }
    }

    private func handleForwardedSample(_ sample: RangingSample) {
        rangingContinuation.yield(sample)
        lastSampleByChannel[sample.channel] = sample.timestamp
        currentDiagnostics.sampleCountByMember[sample.memberID, default: 0] += 1
        currentDiagnostics.lastSampleByMember[sample.memberID] = sample.timestamp
        recomputeActiveChannel()
        maybeYieldDiagnostics()
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

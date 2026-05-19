//
//  UWBSeekingChannel.swift
//  GroupIn
//
//  Thin seeking-tier adapter around `UWBSessionService`. The session
//  service already drives NISession lifecycle, token exchange, and
//  emits `UWBReading`s on its own stream — this channel just maps
//  those into the unified `RangingSample` format so the seeking
//  router can pick it as the top-tier option without the compass code
//  needing a special UWB branch.
//

import Foundation

@MainActor
final class UWBSeekingChannel: SeekingChannel {
    let kind: SeekingChannelKind = .uwb

    let rangingUpdates: AsyncStream<RangingSample>
    private let rangingContinuation: AsyncStream<RangingSample>.Continuation

    private let uwbService: UWBSessionServicing
    private var engagedMembers: Set<UUID> = []
    private var consumerTask: Task<Void, Never>?
    /// Most recent NISession reading per member, used by `isAvailable`
    /// to answer "could UWB take over right now?" — fresh inside ~3s
    /// counts as available, anything older counts as suspended.
    private var lastReadingByMember: [UUID: Date] = [:]
    private static let availabilityWindow: TimeInterval = 3

    init(uwbService: UWBSessionServicing) {
        self.uwbService = uwbService
        let (stream, cont) = AsyncStream.makeStream(of: RangingSample.self)
        self.rangingUpdates = stream
        self.rangingContinuation = cont
        startConsumer()
    }

    func engage(targetMemberID memberID: UUID) {
        guard engagedMembers.insert(memberID).inserted else { return }
        uwbService.start()
        // Token exchange is handled by AppState's existing
        // `startUWBTracking` flow — we don't re-invent it here. The
        // router calls into the seeking channel to engage; AppState
        // handles the side effect of publishing the local token to
        // CloudKit and opening the session against the peer's token
        // once it's known.
    }

    func disengage(targetMemberID memberID: UUID) {
        guard engagedMembers.remove(memberID) != nil else { return }
        uwbService.untrack(memberID: memberID)
        if engagedMembers.isEmpty {
            uwbService.stop()
        }
    }

    func stop() {
        for member in engagedMembers {
            uwbService.untrack(memberID: member)
        }
        engagedMembers.removeAll()
        uwbService.stop()
        consumerTask?.cancel()
        consumerTask = nil
        lastReadingByMember.removeAll()
    }

    func isAvailable(forMember memberID: UUID) -> Bool {
        guard uwbService.isSupported else { return false }
        guard let lastReading = lastReadingByMember[memberID] else { return false }
        return Date().timeIntervalSince(lastReading) < Self.availabilityWindow
    }

    // MARK: - Internals

    private func startConsumer() {
        consumerTask?.cancel()
        consumerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await reading in self.uwbService.readings {
                guard self.engagedMembers.contains(reading.memberID) else {
                    continue
                }
                self.lastReadingByMember[reading.memberID] = reading.timestamp
                self.rangingContinuation.yield(RangingSample(
                    memberID: reading.memberID,
                    distance: reading.distance,
                    direction: reading.direction,
                    rssi: nil,
                    timestamp: reading.timestamp,
                    channel: .uwb
                ))
            }
        }
    }
}

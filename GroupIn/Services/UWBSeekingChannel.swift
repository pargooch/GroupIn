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
        // We only gate which members' readings get FORWARDED to the dial.
        // The NISession lifecycle (start/stop) and `track` are owned by
        // AppState, tied to BLE presence + token exchange — NOT the
        // compass. Recreating the session on every compass open/close
        // minted a new discovery token each time, which broke the
        // bilateral NISession pairing and left one phone with zero
        // readings. Keeping the session stable across open/close is the
        // fix; here we just start/stop forwarding.
        engagedMembers.insert(memberID)
    }

    func disengage(targetMemberID memberID: UUID) {
        // Stop forwarding this member's readings to the dial, but leave
        // the NISession ranging so the link stays warm for re-open and so
        // the peer keeps getting readings from us (ranging is bilateral).
        engagedMembers.remove(memberID)
    }

    func stop() {
        // Channel teardown = stop forwarding only. The session itself is
        // torn down by AppState on `stopBLEPresence`. The consumer task
        // stays alive (it's bound to the channel's lifetime) so a later
        // re-engage resumes forwarding without re-subscribing.
        engagedMembers.removeAll()
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

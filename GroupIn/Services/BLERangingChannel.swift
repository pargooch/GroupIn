//
//  BLERangingChannel.swift
//  GroupIn
//
//  Seeking-tier adapter over `BLEAdvertisementService`. When engaged
//  for a member, asks the BLE service to start active `readRSSI()`
//  polling on that member's live GATT connection at 5 Hz — same RSSI
//  values you'd get from scan callbacks, but several times denser and
//  importantly still flowing while the peer is backgrounded.
//
//  The channel filters `BLEAdvertisementService.rssiUpdates` down to
//  the engaged member set and emits `RangingSample`s for the seeking
//  router. UWB-only fields (distance, direction) stay nil — BLE
//  gives us proximity, not range.
//

import Foundation

@MainActor
final class BLERangingChannel: SeekingChannel {
    let kind: SeekingChannelKind = .bleRanging

    let rangingUpdates: AsyncStream<RangingSample>
    private let rangingContinuation: AsyncStream<RangingSample>.Continuation

    private let bleService: BLEPresenceServicing
    private var engagedMembers: Set<UUID> = []
    private var consumerTask: Task<Void, Never>?

    init(bleService: BLEPresenceServicing) {
        self.bleService = bleService
        let (stream, cont) = AsyncStream.makeStream(of: RangingSample.self)
        self.rangingUpdates = stream
        self.rangingContinuation = cont
        startConsumer()
    }

    func engage(targetMemberID memberID: UUID) {
        guard engagedMembers.insert(memberID).inserted else { return }
        bleService.startActiveRSSIPolling(for: memberID)
    }

    func disengage(targetMemberID memberID: UUID) {
        guard engagedMembers.remove(memberID) != nil else { return }
        bleService.stopActiveRSSIPolling(for: memberID)
    }

    func stop() {
        for member in engagedMembers {
            bleService.stopActiveRSSIPolling(for: member)
        }
        engagedMembers.removeAll()
        consumerTask?.cancel()
        consumerTask = nil
    }

    func isAvailable(forMember memberID: UUID) -> Bool {
        // Floor channel — always available once BLE is up. The router
        // treats this as the fallback so we don't gate availability
        // here; if BLE itself is off, samples just stop arriving and
        // the consumer sees nothing, same as any other channel.
        true
    }

    // MARK: - Internals

    private func startConsumer() {
        consumerTask?.cancel()
        consumerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await reading in self.bleService.rssiUpdates {
                // Filter down to engaged members — the BLE service's
                // stream carries every RSSI we receive, not just the
                // ones we're actively seeking. The compass only cares
                // about the engaged set.
                guard self.engagedMembers.contains(reading.memberID) else {
                    continue
                }
                self.rangingContinuation.yield(RangingSample(
                    memberID: reading.memberID,
                    distance: nil,
                    direction: nil,
                    rssi: reading.rssi,
                    timestamp: reading.timestamp,
                    channel: .bleRanging
                ))
            }
        }
    }
}

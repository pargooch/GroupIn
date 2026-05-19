//
//  WiFiAwareRangingChannel.swift
//  GroupIn
//
//  Seeking-tier scaffold for Wi-Fi Aware (NAN) FTM ranging. Mirrors
//  the structure of `BLERangingChannel` / `UWBSeekingChannel` so the
//  router can pick it the moment the framework + entitlement are
//  wired. Until then `isAvailable` returns false and the router falls
//  through to BLE — same pattern as `WiFiAwareService` on the payload
//  side.
//
//  TODO(Phase 4 follow-up): real implementation will stand up a
//  `WAPublishableService` + `WASubscribableService` with the rendezvous
//  token in the service name, then call `WAPair.range(...)` on each
//  match for periodic FTM distance reports. Both distance and RSSI
//  surface in the match payload.
//

import Foundation

@MainActor
final class WiFiAwareRangingChannel: SeekingChannel {
    let kind: SeekingChannelKind = .wifiAwareRanging

    let rangingUpdates: AsyncStream<RangingSample>
    private let rangingContinuation: AsyncStream<RangingSample>.Continuation

    private var engagedMembers: Set<UUID> = []

    init() {
        let (stream, cont) = AsyncStream.makeStream(of: RangingSample.self)
        self.rangingUpdates = stream
        self.rangingContinuation = cont
    }

    func engage(targetMemberID memberID: UUID) {
        engagedMembers.insert(memberID)
        // TODO: start WAPublishableService + range subscription.
    }

    func disengage(targetMemberID memberID: UUID) {
        engagedMembers.remove(memberID)
        // TODO: stop ranging for this peer.
    }

    func stop() {
        engagedMembers.removeAll()
        // TODO: tear down publisher / subscriber.
    }

    func isAvailable(forMember memberID: UUID) -> Bool {
        // Stub: until the framework is wired, this is never the active
        // channel. Capability negotiation will short-circuit to BLE
        // because `wifiAwareRanging` reports `false` on both sides.
        false
    }
}

//
//  SeekingChannel.swift
//  GroupIn
//
//  Unified surface for the "seeking tier" — anything that produces a
//  range or bearing observation between the local user (seeker) and a
//  targeted peer (sought). Concrete channels: UWB (centimeter accuracy
//  + direction), Wi-Fi Aware FTM (meter accuracy + RSSI), and BLE RSSI
//  polling (RSSI only, but always available). The router below picks
//  the highest tier supported by both peers and forwards its output to
//  the compass under one stable stream.
//
//  Architecture mirrors `PayloadTransport` for the chat / event-log
//  tier: protocol, capability negotiation, router. Two parallel
//  hierarchies, one wire-format struct.
//

import Foundation

/// One ranging or bearing observation, normalized across channels.
/// Different channels populate different optional fields:
///   • UWB → distance, direction, rssi may be nil.
///   • Wi-Fi Aware (FTM) → distance + rssi; direction nil unless
///     beam-steering surfaces it (not yet).
///   • BLE → rssi only; distance/direction nil.
nonisolated struct RangingSample: Sendable {
    let memberID: UUID
    let distance: Float?
    let direction: SIMD3<Float>?
    let rssi: Double?
    let timestamp: Date
    let channel: SeekingChannelKind
}

/// Identifies which channel produced a sample / is currently engaged.
nonisolated enum SeekingChannelKind: String, Sendable, Equatable, Codable {
    case uwb
    case wifiAwareRanging
    case bleRanging
}

/// Diagnostics for a seeking channel — surfaced in the indoor strip so
/// the user can see which channel is driving the compass and how
/// healthy it looks.
nonisolated struct SeekingDiagnostics: Sendable, Equatable {
    var activeChannel: SeekingChannelKind?
    var sampleCountByMember: [UUID: Int]
    var lastSampleByMember: [UUID: Date]

    static let empty = SeekingDiagnostics(
        activeChannel: nil,
        sampleCountByMember: [:],
        lastSampleByMember: [:]
    )
}

/// Common surface for any concrete seeking channel. Mirrors
/// `PayloadTransport` — small, stream-driven, lifecycle-tagged.
@MainActor
protocol SeekingChannel: AnyObject {
    /// Channel kind — used by the router to advertise which channel
    /// is currently engaged.
    var kind: SeekingChannelKind { get }

    /// Stream of ranging samples from this channel. Continuations live
    /// for the channel's lifetime; consumers attach once.
    var rangingUpdates: AsyncStream<RangingSample> { get }

    /// Engage active sampling for a specific peer. Calling again with
    /// the same memberID is a no-op. Channels are responsible for any
    /// underlying connection / session lifecycle.
    func engage(targetMemberID: UUID)

    /// Stop active sampling for a peer. Idempotent.
    func disengage(targetMemberID: UUID)

    /// Stop everything — called when the seeking session winds down
    /// (compass closes, user leaves group).
    func stop()

    /// Whether this channel is *currently* available for the given
    /// peer. UWB returns false when either side is backgrounded
    /// (NISession suspended), Wi-Fi Aware returns false on devices
    /// without entitlement, etc. BLE returns true whenever the
    /// peripheral is connected and mapped.
    func isAvailable(forMember memberID: UUID) -> Bool
}

/// Capability-based selection. Pure function — no I/O, no actor work.
/// Mirrors `TransportCapability.groupMinimum(across:)` but for the
/// per-pair seeking tier rather than the group-wide payload tier.
enum SeekingChannelSelector {
    /// Pick the best channel supported by both sides for a single
    /// seeker → sought pairing. UWB takes precedence when both sides
    /// have it; Wi-Fi Aware next; BLE as floor (always works).
    static func bestChannel(
        local: TransportCapability,
        peer: TransportCapability
    ) -> SeekingChannelKind {
        if local.uwb && peer.uwb { return .uwb }
        if local.wifiAwareRanging && peer.wifiAwareRanging { return .wifiAwareRanging }
        return .bleRanging
    }
}

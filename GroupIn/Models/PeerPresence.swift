//
//  PeerPresence.swift
//  GroupIn
//
//  The on-air payload exchanged between GroupIn devices over BLE. Kept
//  small and self-describing — Codable JSON for now (~150 bytes), will
//  switch to a tighter binary format in the radio-module phase.
//

import Foundation

struct PeerPresence: Codable, Equatable {
    /// Hash derived from the active group's invite code. Devices ignore
    /// presence packets whose hash doesn't match their own active group,
    /// which keeps cross-group BLE chatter out.
    let groupHash: UInt32

    /// The peer's per-group membership UUID.
    let memberID: UUID

    /// Peer's display name. Carried in the BLE presence so receivers
    /// can render an actual name immediately instead of stubbing the
    /// member with "Member" and waiting on event-log gossip — that
    /// gossip rides on the higher-tier payload transport which may
    /// not be connected (Local Network permission declined, peer
    /// backgrounded, transport not yet up). BLE presence is the only
    /// always-on signaling channel; identity belongs here. Optional
    /// for backwards-compat with older clients that didn't include it.
    let displayName: String?

    let latitude: Double?
    let longitude: Double?

    /// Compass heading in degrees from true north, when the peer's device
    /// has a valid reading. Nil otherwise.
    let heading: Double?

    /// When the peer's location was sampled (UTC).
    let lastSeen: Date

    // Provenance — same shape as on the CloudKit User record. BLE
    // peers exchange these alongside the coordinate so locally-
    // received positions carry the same context as CloudKit-fetched
    // ones. All optional for backwards-compat with older clients
    // that send the slimmer original payload.

    /// Horizontal accuracy in meters of the broadcast coordinate.
    let accuracy: Double?
    /// Provenance for the broadcast coordinate. Raw-string-encoded
    /// so devices running an older PositionSource enum don't choke;
    /// unknown values decode to nil and are treated as `.gps`.
    let positionSource: String?
    /// For `.deadReckoning`: when the last real GPS fix was taken.
    let positionAnchorAt: Date?

    // Event log cursor — the last event in this peer's local log. The
    // pair `(createdAt, id)` matches `EventCursor` exactly. Receivers
    // compare against their own cursor to decide whether they have
    // events the peer is missing (and should push them) or are
    // behind themselves. Both nil means the peer is running an older
    // build without C.3, or has never received any events yet — treat
    // as "no cursor known" and skip cursor-mismatch logic.
    let eventCursorCreatedAt: Date?
    let eventCursorID: UUID?

    /// What payload transports this peer can drive. The group-min
    /// across every member's capability set selects the active
    /// transport for the group. Missing field (older clients) decodes
    /// to nil → treated as "MPC only" since every iOS device can do
    /// that.
    let transportCapability: TransportCapability?

    init(groupHash: UInt32,
         memberID: UUID,
         displayName: String? = nil,
         latitude: Double?,
         longitude: Double?,
         heading: Double?,
         lastSeen: Date,
         accuracy: Double? = nil,
         positionSource: String? = nil,
         positionAnchorAt: Date? = nil,
         eventCursor: EventCursor? = nil,
         transportCapability: TransportCapability? = nil) {
        self.groupHash = groupHash
        self.memberID = memberID
        self.displayName = displayName
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.lastSeen = lastSeen
        self.accuracy = accuracy
        self.positionSource = positionSource
        self.positionAnchorAt = positionAnchorAt
        self.eventCursorCreatedAt = eventCursor?.createdAt
        self.eventCursorID = eventCursor?.id
        self.transportCapability = transportCapability
    }

    /// Materialized event cursor, or nil if either field is missing.
    var eventCursor: EventCursor? {
        guard let date = eventCursorCreatedAt, let id = eventCursorID
        else { return nil }
        return EventCursor(createdAt: date, id: id)
    }

    /// Forgiving decoder so older clients sending the pre-Path-B/C
    /// payload still parse cleanly. Missing fields default to nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupHash = try c.decode(UInt32.self, forKey: .groupHash)
        self.memberID = try c.decode(UUID.self, forKey: .memberID)
        self.displayName = try? c.decode(String.self, forKey: .displayName)
        self.latitude = try? c.decode(Double.self, forKey: .latitude)
        self.longitude = try? c.decode(Double.self, forKey: .longitude)
        self.heading = try? c.decode(Double.self, forKey: .heading)
        self.lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        self.accuracy = try? c.decode(Double.self, forKey: .accuracy)
        self.positionSource = try? c.decode(String.self, forKey: .positionSource)
        self.positionAnchorAt = try? c.decode(Date.self, forKey: .positionAnchorAt)
        self.eventCursorCreatedAt = try? c.decode(Date.self, forKey: .eventCursorCreatedAt)
        self.eventCursorID = try? c.decode(UUID.self, forKey: .eventCursorID)
        self.transportCapability = try? c.decode(TransportCapability.self, forKey: .transportCapability)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> PeerPresence? {
        try? JSONDecoder().decode(PeerPresence.self, from: data)
    }

    /// 32-bit FNV-1a hash of the uppercased invite code. Stable across
    /// devices, low-collision enough for our use (~6 chars from a
    /// 32-symbol alphabet → tiny address space, wide hash output).
    static func groupHash(forInviteCode code: String) -> UInt32 {
        let normalized = code.uppercased()
        let bytes = Array(normalized.utf8)
        var hash: UInt32 = 2_166_136_261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

extension UUID {
    /// First 16 bits of the UUID's raw bytes. Used as the iBeacon
    /// `minor` to identify a member at the radio layer (16-bit space
    /// is enough for groups under ~1000 members; collisions extremely
    /// rare at festival group sizes).
    var truncated16: UInt16 {
        let raw = uuid
        return (UInt16(raw.0) << 8) | UInt16(raw.1)
    }
}

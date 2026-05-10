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

    let latitude: Double?
    let longitude: Double?

    /// Compass heading in degrees from true north, when the peer's device
    /// has a valid reading. Nil otherwise.
    let heading: Double?

    /// When the peer's location was sampled (UTC).
    let lastSeen: Date

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

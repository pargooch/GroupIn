//
//  PayloadFrame.swift
//  GroupIn
//
//  Wire envelope for the payload transport (MPC / Wi-Fi Aware). Every
//  message exchanged over the transport is one of these. BLE keeps its
//  own per-characteristic encoding (PeerPresence JSON, JoinRequest /
//  JoinResponse) — only the *payload tier* uses this frame.
//
//  Versioning lives at the case level: when v2 adds new message types
//  (capability, anchor, encrypted-envelope, ...) they become new
//  cases. JSONDecoder fails closed on unknown discriminators, which is
//  what we want — a v2 sender talking to a v1 receiver silently drops
//  cases the v1 receiver doesn't understand.
//

import Foundation

nonisolated enum PayloadFrame: Codable, Sendable {
    /// An event log entry. The unified gossip channel for the entire
    /// event timeline — chat messages, member joins, extensions,
    /// removals — all flow as events here. No `strippedForBLE()`
    /// shrinkage because the transport can carry the full payload
    /// including avatars.
    case event(Event)

    /// A member's identity (name + avatar) pushed directly to connected
    /// peers. The event log already carries avatars inside `memberJoined`,
    /// but those are stripped before persistence and a peer may connect
    /// long after the join, so this frame lets a freshly-connected device
    /// learn everyone's profile picture immediately — over MPC / Wi-Fi
    /// Aware, which has capacity for the avatar blob — instead of waiting
    /// on a CloudKit round-trip. It is NOT a timeline event: receivers
    /// apply it to the member record and emit nothing.
    case profile(MemberProfile)

    /// Cursor advertisement — sent by a peer right after the MPC session
    /// comes up, telling us "for this group, this is the most recent
    /// event I have." We compare to our local timeline and stream back
    /// every event newer than `cursor` in chronological order. This is
    /// the targeted handshake that fixes the "join a group, chat doesn't
    /// sync until app restart" symptom: the cold-start sync used to
    /// happen via CloudKit only and could lag minutes; this is a direct
    /// peer-to-peer catch-up that completes the moment the link is up.
    case cursorAdvert(CursorAdvert)

    /// Delivery receipt — broadcast back to the author the moment we
    /// ingest one of their events. Carries an explicit timestamp so
    /// the author can show "delivered at HH:MM" in the message-info
    /// sheet, not just "delivered." Sent to the WHOLE group (the
    /// author doesn't know who has a session with whom); peers other
    /// than the author drop it on receive.
    case deliveryReceipt(DeliveryReceipt)

    /// Read receipt — broadcast back to the author when their event
    /// has been visible on our chat row for ≥500ms. WhatsApp's blue
    /// double-check semantics. Same broadcast pattern as delivery.
    case readReceipt(ReadReceipt)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case event
        case profile
        case cursorAdvert
        case deliveryReceipt
        case readReceipt
    }

    private enum Kind: String, Codable {
        case event
        case profile
        case cursorAdvert
        case deliveryReceipt
        case readReceipt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .event:
            let event = try container.decode(Event.self, forKey: .event)
            self = .event(event)
        case .profile:
            let profile = try container.decode(MemberProfile.self, forKey: .profile)
            self = .profile(profile)
        case .cursorAdvert:
            let advert = try container.decode(CursorAdvert.self, forKey: .cursorAdvert)
            self = .cursorAdvert(advert)
        case .deliveryReceipt:
            let r = try container.decode(DeliveryReceipt.self, forKey: .deliveryReceipt)
            self = .deliveryReceipt(r)
        case .readReceipt:
            let r = try container.decode(ReadReceipt.self, forKey: .readReceipt)
            self = .readReceipt(r)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode(Kind.event, forKey: .type)
            try container.encode(event, forKey: .event)
        case .profile(let profile):
            try container.encode(Kind.profile, forKey: .type)
            try container.encode(profile, forKey: .profile)
        case .cursorAdvert(let advert):
            try container.encode(Kind.cursorAdvert, forKey: .type)
            try container.encode(advert, forKey: .cursorAdvert)
        case .deliveryReceipt(let r):
            try container.encode(Kind.deliveryReceipt, forKey: .type)
            try container.encode(r, forKey: .deliveryReceipt)
        case .readReceipt(let r):
            try container.encode(Kind.readReceipt, forKey: .type)
            try container.encode(r, forKey: .readReceipt)
        }
    }

    // MARK: Convenience

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> PayloadFrame? {
        try? JSONDecoder().decode(PayloadFrame.self, from: data)
    }
}

/// Identity payload for the `.profile` frame: who, in which group, with
/// what name and avatar. Shared `groupID` / `memberID` match the values
/// on the synced group, so receivers can patch the right member record.
nonisolated struct MemberProfile: Codable, Sendable, Equatable {
    let groupID: UUID
    let memberID: UUID
    let displayName: String?
    let avatarData: Data?
}

/// Payload for `.cursorAdvert`: the sender's most recent known event
/// cursor for `groupID`. `cursor == nil` means "I have no events for
/// this group yet" — receivers should treat that as "stream me
/// everything." Sent once per group right after the MPC session for
/// that group transitions to `.connected`.
nonisolated struct CursorAdvert: Codable, Sendable {
    let groupID: UUID
    let cursor: EventCursor?
}

/// Payload for `.deliveryReceipt`: who received which event, when.
/// Sent by the receiver back to the group the moment they ingest a
/// gossiped event. Only the author (`event.authorID`) consumes it;
/// other peers drop on receive.
nonisolated struct DeliveryReceipt: Codable, Sendable {
    let groupID: UUID
    let eventID: UUID
    let receiverID: UUID
    let at: Date
}

/// Payload for `.readReceipt`: who actually displayed which event on
/// their screen for ≥500ms. Authored by the receiver; consumed by
/// the author to upgrade their indicator to blue ✓✓.
nonisolated struct ReadReceipt: Codable, Sendable {
    let groupID: UUID
    let eventID: UUID
    let readerID: UUID
    let at: Date
}

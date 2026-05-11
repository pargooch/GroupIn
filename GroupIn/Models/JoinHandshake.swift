//
//  JoinHandshake.swift
//  GroupIn
//
//  Wire format for the BLE-mediated join protocol — the offline
//  discovery path where a prospective member finds an in-range group
//  member by invite code and pulls the group's identity directly,
//  without involving CloudKit. The pattern is:
//
//    Joiner → JoinRequest (write to in-range peer's GATT)
//    Peer   → JoinResponse (notify back to the writing central)
//
//  Both payloads are JSON-encoded `Codable` so we keep the wire format
//  trivially readable for debugging. Both stay well under the BLE
//  GATT MTU (~185 bytes after iOS overhead) by carrying only the
//  minimum identity bits — full member lists and chat history are
//  reconstructed via the normal event-log gossip after the joiner
//  is in.
//

import Foundation

/// What the prospective member writes to a peer's GATT to ask "do
/// you have a group with this invite code?". The peer's response is
/// either silence (if their active group's invite code doesn't match)
/// or a `JoinResponse` carrying the group identity.
struct JoinRequest: Codable, Hashable, Sendable {
    let inviteCode: String
    /// Joiner's salted ban hash for this invite code. Lets the peer
    /// reject pre-banned joiners *before* shipping group identity
    /// over the air. Nil when the joiner isn't signed into iCloud
    /// (no stable identity to ban).
    let joinerBanHash: String?
    /// Joiner's per-group membership ID + display name. The peer
    /// emits a `memberJoined` event on their behalf so other members
    /// see the join even if the joiner's own publish fails. Avatar
    /// data is omitted to keep the request under MTU — it syncs via
    /// CloudKit once the joiner's User CKRecord publishes.
    let joinerMemberID: UUID
    let joinerDisplayName: String

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> JoinRequest? {
        try? JSONDecoder().decode(JoinRequest.self, from: data)
    }
}

/// What an in-range group member writes back when a joiner's invite
/// code matches their active group. Carries just enough identity for
/// the joiner to bootstrap a local GroupSession — members, banlist,
/// and chat history catch up via the event log over the next few
/// seconds.
struct JoinResponse: Codable, Hashable, Sendable {
    let groupID: UUID
    let name: String
    let inviteCode: String
    let category: String     // GroupCategory raw value
    let ownerID: UUID
    let createdAt: Date
    let expiresAt: Date
    /// Member ID of the responding peer. Lets the joiner record where
    /// the response came from for diagnostics; not load-bearing.
    let responderMemberID: UUID

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> JoinResponse? {
        try? JSONDecoder().decode(JoinResponse.self, from: data)
    }

    /// Materialize a minimal `GroupSession` from the response. The
    /// member list and banlist are empty — the joiner picks those up
    /// via gossip immediately after this lands.
    func toGroupSession() -> GroupSession? {
        guard let category = GroupCategory(rawValue: category) else { return nil }
        return GroupSession(
            id: groupID,
            name: name,
            inviteCode: inviteCode,
            category: category,
            ownerID: ownerID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            members: [],
            pendingExtension: nil,
            bannedMembers: []
        )
    }
}

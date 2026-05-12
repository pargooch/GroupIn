//
//  Event.swift
//  GroupIn
//
//  An append-only record of something that happened in a group.
//  Every state-changing action (joins, kicks, bans, extensions, chat
//  messages) becomes one of these and lands in the group's event log
//  on CloudKit. The reducer (see `EventReducer.swift`) folds a sorted
//  stream of events into a `GroupSession` snapshot — so state isn't
//  mutated directly, it's *derived* from history.
//
//  Why this exists:
//    • Reliable moderation propagation (a ban is one event; replaying
//      events on a recipient guarantees they see it).
//    • Foundation for offline gossip relay (Path C.3) — events are
//      content-addressable and can be exchanged peer-to-peer.
//    • WhatsApp-style delivery acknowledgment (Path C.4).
//    • Unified timeline UI mixing chat and structural events.
//
//  Ordering: `(createdAt, id)` lexicographic — wall-clock time plus
//  a UUID tiebreaker. Every device sees the same total order because
//  both fields are immutable parts of the event itself. Clock skew
//  between devices may shift display ordering slightly under bad
//  conditions, but state derivation is still deterministic.
//

import Foundation
import CryptoKit

/// One immutable event. The `payload` carries the type discriminator
/// implicitly (via its enum case), so there's no separate `EventType`
/// field — a single switch statement covers all per-type handling.
struct Event: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let groupID: UUID
    let authorID: UUID
    let createdAt: Date
    let payload: EventPayload

    init(id: UUID = UUID(),
         groupID: UUID,
         authorID: UUID,
         createdAt: Date = .now,
         payload: EventPayload) {
        self.id = id
        self.groupID = groupID
        self.authorID = authorID
        self.createdAt = createdAt
        self.payload = payload
    }

    /// Stable string discriminator for indexing and CloudKit query
    /// support. Mirrors the case names so future "show me only chat
    /// events" filters can predicate on `type ==`.
    var typeIdentifier: String { payload.typeIdentifier }
}

/// Typed per-case payload for an `Event`. New event types are added
/// here; the reducer's exhaustive switch catches missing handlers at
/// compile time.
enum EventPayload: Hashable, Sendable {
    case groupCreated(name: String,
                      inviteCode: String,
                      category: GroupCategory,
                      expiresAt: Date)
    case memberJoined(memberID: UUID,
                      displayName: String,
                      avatarData: Data?,
                      banHash: String?)
    case memberRemoved(memberID: UUID,
                       displayName: String,
                       banHash: String?)
    case memberLeft(memberID: UUID)
    case memberUnbanned(banHash: String)
    case extensionProposed(newExpiresAt: Date)
    case extensionAccepted(memberID: UUID)
    case extensionResolved(newExpiresAt: Date)
    case chatMessage(text: String)
    /// Owner-initiated hard delete. Carries no payload — the
    /// receiver tears down the group identified by `event.groupID`.
    /// Lets the offline-bulletproof path propagate deletions via
    /// BLE gossip and the persisted event log instead of relying on
    /// each peer to *miss* the CKRecord and infer deletion.
    case groupDeleted

    var typeIdentifier: String {
        switch self {
        case .groupCreated:        return "groupCreated"
        case .memberJoined:        return "memberJoined"
        case .memberRemoved:       return "memberRemoved"
        case .memberLeft:          return "memberLeft"
        case .memberUnbanned:      return "memberUnbanned"
        case .extensionProposed:   return "extensionProposed"
        case .extensionAccepted:   return "extensionAccepted"
        case .extensionResolved:   return "extensionResolved"
        case .chatMessage:         return "chatMessage"
        case .groupDeleted:        return "groupDeleted"
        }
    }
}

// MARK: - Codable

extension EventPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        // Per-case keys. We use one flat set of keys with a `kind`
        // discriminator rather than nested containers — keeps the
        // encoded JSON readable and slightly smaller.
        case name, inviteCode, category, expiresAt
        case memberID, displayName, avatarData, banHash
        case newExpiresAt, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "groupCreated":
            self = .groupCreated(
                name: try c.decode(String.self, forKey: .name),
                inviteCode: try c.decode(String.self, forKey: .inviteCode),
                category: try c.decode(GroupCategory.self, forKey: .category),
                expiresAt: try c.decode(Date.self, forKey: .expiresAt)
            )
        case "memberJoined":
            self = .memberJoined(
                memberID: try c.decode(UUID.self, forKey: .memberID),
                displayName: try c.decode(String.self, forKey: .displayName),
                avatarData: try? c.decode(Data.self, forKey: .avatarData),
                banHash: try? c.decode(String.self, forKey: .banHash)
            )
        case "memberRemoved":
            self = .memberRemoved(
                memberID: try c.decode(UUID.self, forKey: .memberID),
                displayName: try c.decode(String.self, forKey: .displayName),
                banHash: try? c.decode(String.self, forKey: .banHash)
            )
        case "memberLeft":
            self = .memberLeft(
                memberID: try c.decode(UUID.self, forKey: .memberID)
            )
        case "memberUnbanned":
            self = .memberUnbanned(
                banHash: try c.decode(String.self, forKey: .banHash)
            )
        case "extensionProposed":
            self = .extensionProposed(
                newExpiresAt: try c.decode(Date.self, forKey: .newExpiresAt)
            )
        case "extensionAccepted":
            self = .extensionAccepted(
                memberID: try c.decode(UUID.self, forKey: .memberID)
            )
        case "extensionResolved":
            self = .extensionResolved(
                newExpiresAt: try c.decode(Date.self, forKey: .newExpiresAt)
            )
        case "chatMessage":
            self = .chatMessage(
                text: try c.decode(String.self, forKey: .text)
            )
        case "groupDeleted":
            self = .groupDeleted
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown event kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeIdentifier, forKey: .kind)
        switch self {
        case .groupCreated(let name, let inviteCode, let category, let expiresAt):
            try c.encode(name, forKey: .name)
            try c.encode(inviteCode, forKey: .inviteCode)
            try c.encode(category, forKey: .category)
            try c.encode(expiresAt, forKey: .expiresAt)
        case .memberJoined(let memberID, let displayName, let avatarData, let banHash):
            try c.encode(memberID, forKey: .memberID)
            try c.encode(displayName, forKey: .displayName)
            try c.encodeIfPresent(avatarData, forKey: .avatarData)
            try c.encodeIfPresent(banHash, forKey: .banHash)
        case .memberRemoved(let memberID, let displayName, let banHash):
            try c.encode(memberID, forKey: .memberID)
            try c.encode(displayName, forKey: .displayName)
            try c.encodeIfPresent(banHash, forKey: .banHash)
        case .memberLeft(let memberID):
            try c.encode(memberID, forKey: .memberID)
        case .memberUnbanned(let banHash):
            try c.encode(banHash, forKey: .banHash)
        case .extensionProposed(let newExpiresAt):
            try c.encode(newExpiresAt, forKey: .newExpiresAt)
        case .extensionAccepted(let memberID):
            try c.encode(memberID, forKey: .memberID)
        case .extensionResolved(let newExpiresAt):
            try c.encode(newExpiresAt, forKey: .newExpiresAt)
        case .chatMessage(let text):
            try c.encode(text, forKey: .text)
        case .groupDeleted:
            break
        }
    }
}

// MARK: - Sync cursor

/// "Up to and including this event" marker. Devices persist their
/// per-group cursor locally and ask CloudKit (or BLE peers) for
/// anything strictly newer. `(createdAt, id)` ordering ensures the
/// cursor is monotonic across the cluster.
struct EventCursor: Hashable, Codable, Sendable {
    let createdAt: Date
    let id: UUID

    static func > (lhs: EventCursor, rhs: EventCursor) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static func < (lhs: EventCursor, rhs: EventCursor) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

extension Event {
    /// The cursor that points at this event. Cursor comparisons let
    /// peers ask "what's newer than X?" without needing the whole
    /// event to be in hand.
    var cursor: EventCursor {
        EventCursor(createdAt: createdAt, id: id)
    }

    /// Human-readable text for the timeline's centered "system row"
    /// rendering of structural events. Returns nil for `.chatMessage`
    /// — those render as bubbles, not system rows, so the caller
    /// switches to the bubble path when it sees nil here.
    ///
    /// `members` provides a name lookup for events that reference a
    /// member by ID. Falls back to "a member" if the ID isn't in the
    /// current snapshot (e.g. the member already left and was pruned).
    /// `ownerID` distinguishes the group owner in events that name
    /// them implicitly ("Owner extended the group").
    func displayDescription(in members: [User], ownerID: UUID) -> String? {
        func name(_ id: UUID) -> String {
            members.first(where: { $0.id == id })?.displayName ?? "A member"
        }
        let actor = (authorID == ownerID) ? "Owner" : name(authorID)

        switch payload {
        case .chatMessage:
            return nil

        case .groupCreated(let name, _, _, _):
            return "\(actor) created “\(name)”"

        case .memberJoined(_, let displayName, _, _):
            return "\(displayName) joined"

        case .memberRemoved(_, let displayName, _):
            return "\(displayName) was removed by \(actor)"

        case .memberLeft(let memberID):
            return "\(name(memberID)) left"

        case .memberUnbanned:
            return "\(actor) lifted a ban"

        case .extensionProposed(let newExpiresAt):
            let when = newExpiresAt.formatted(date: .omitted, time: .shortened)
            return "\(actor) proposed extending until \(when)"

        case .extensionAccepted(let memberID):
            return "\(name(memberID)) accepted the extension"

        case .extensionResolved(let newExpiresAt):
            let when = newExpiresAt.formatted(date: .abbreviated, time: .shortened)
            return "Group extended until \(when)"

        case .groupDeleted:
            return "\(actor) deleted the group"
        }
    }

    /// Deterministic event ID for `memberJoined` derived from
    /// `(groupID, memberID)`. Two devices (the joiner and a BLE
    /// responder) can emit the same join independently with the
    /// same event ID, so the ingest-level dedup in `AppState`
    /// collapses them into one log entry — keeping the timeline
    /// clean even when both sides commit the join in parallel.
    ///
    /// Not RFC 4122 v5 compliant (no namespace UUID, no version /
    /// variant bits set), but stable as a dedup key, which is the
    /// only property we need here.
    static func memberJoinedEventID(groupID: UUID, memberID: UUID) -> UUID {
        var data = Data()
        withUnsafeBytes(of: groupID.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: memberID.uuid) { data.append(contentsOf: $0) }
        data.append(Data("memberJoined".utf8))
        let digest = SHA256.hash(data: data)
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A copy of this event safe to send over BLE — large blobs
    /// stripped so the encoded payload fits in a single GATT write
    /// (~185 bytes on iOS after overhead). The receiver will sync
    /// the missing data (e.g. avatars) via CloudKit on the next
    /// refresh; events are about *what happened*, not the entire
    /// asset blob attached to it.
    ///
    /// Currently only `memberJoined` carries an `avatarData`. Other
    /// payloads pass through unchanged.
    func strippedForBLE() -> Event {
        switch payload {
        case .memberJoined(let memberID, let displayName, _, let banHash):
            return Event(
                id: id,
                groupID: groupID,
                authorID: authorID,
                createdAt: createdAt,
                payload: .memberJoined(
                    memberID: memberID,
                    displayName: displayName,
                    avatarData: nil,
                    banHash: banHash
                )
            )
        default:
            return self
        }
    }
}

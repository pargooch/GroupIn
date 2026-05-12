//
//  EventReducer.swift
//  GroupIn
//
//  Pure folding of an Event stream into a GroupSession snapshot.
//  Deterministic: every device that sees the same set of events
//  computes the same state, regardless of the order they arrived.
//
//  Sort order is `(createdAt, id)` — wall-clock time plus a UUID
//  tiebreaker — so the fold is stable even when two events share
//  the exact same millisecond.
//
//  This reducer is intentionally *additive* on top of the existing
//  state mutation paths in AppState for Path C.1+C.2. Direct CloudKit
//  state changes still happen; events are folded in as a parallel
//  source of truth. Once Path C.3 (BLE gossip) lands and event
//  transport proves reliable, the direct mutations get retired and
//  the reducer becomes the only path from events to state.
//

import Foundation

enum EventReducer {
    /// Fold a list of events into a GroupSession snapshot. Optionally
    /// builds on top of an existing snapshot — passing `into:` lets us
    /// apply only newly-fetched events without re-replaying the
    /// entire history.
    static func reduce(_ events: [Event],
                       into initialState: GroupSession? = nil) -> GroupSession? {
        let sorted = events.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return sorted.reduce(initialState) { state, event in
            apply(event, to: state)
        }
    }

    /// Apply one event. Idempotency: applying the same event twice to
    /// the same state produces the same state both times (members
    /// joined twice = still one entry, etc.). This keeps the reducer
    /// safe under at-least-once delivery semantics from the gossip
    /// layer.
    static func apply(_ event: Event, to state: GroupSession?) -> GroupSession? {
        switch event.payload {

        case .groupCreated(let name, let inviteCode, let category, let expiresAt):
            // First event in a group's history. Mints the empty
            // session — members and banlist arrive via subsequent
            // events. The owner's `memberJoined` is emitted alongside
            // `groupCreated` so the owner shows up in the next event.
            return GroupSession(
                id: event.groupID,
                name: name,
                inviteCode: inviteCode,
                category: category,
                ownerID: event.authorID,
                expiresAt: expiresAt,
                createdAt: event.createdAt
            )

        case .memberJoined(let memberID, let displayName, let avatarData, let banHash):
            guard var state else { return nil }
            let user = User(
                id: memberID,
                displayName: displayName,
                avatarData: avatarData,
                lastSeen: event.createdAt,
                banHash: banHash
            )
            // Idempotent on memberID — re-applying the same join
            // updates the existing row rather than duplicating it.
            if let idx = state.members.firstIndex(where: { $0.id == memberID }) {
                // Keep position/heading data from the existing record
                // (the join event has no positional info), just refresh
                // identity bits.
                state.members[idx].displayName = displayName
                state.members[idx].avatarData = avatarData
                state.members[idx].banHash = banHash
            } else {
                state.members.append(user)
            }
            return state

        case .memberRemoved(let memberID, let displayName, let banHash):
            guard var state else { return nil }
            state.members.removeAll { $0.id == memberID }
            // Append to banlist if this member had a hash. Idempotent —
            // the same hash never gets two banlist entries.
            if let hash = banHash,
               !state.bannedMembers.contains(where: { $0.banHash == hash }) {
                state.bannedMembers.append(BannedMember(
                    banHash: hash,
                    displayName: displayName,
                    bannedAt: event.createdAt
                ))
            }
            return state

        case .memberLeft(let memberID):
            // Voluntary leave — no banlist write.
            guard var state else { return nil }
            state.members.removeAll { $0.id == memberID }
            return state

        case .memberUnbanned(let banHash):
            guard var state else { return nil }
            state.bannedMembers.removeAll { $0.banHash == banHash }
            return state

        case .extensionProposed(let newExpiresAt):
            guard var state else { return nil }
            state.pendingExtension = PendingExtension(
                newExpiresAt: newExpiresAt,
                proposedAt: event.createdAt,
                acceptedMemberIDs: []
            )
            return state

        case .extensionAccepted(let memberID):
            guard var state, var pending = state.pendingExtension else { return state }
            if !pending.acceptedMemberIDs.contains(memberID) {
                pending.acceptedMemberIDs.append(memberID)
            }
            state.pendingExtension = pending
            return state

        case .extensionResolved(let newExpiresAt):
            guard var state else { return nil }
            state.expiresAt = newExpiresAt
            state.pendingExtension = nil
            return state

        case .chatMessage:
            // Chat messages don't currently modify the GroupSession
            // snapshot — they're rendered separately by the timeline
            // UI (Path C.4). Keeping them in the event log here gives
            // C.4 a free historical record to display when it lands.
            return state

        case .groupDeleted:
            // The owner has hard-deleted the group. The reducer can't
            // signal "remove this group from myGroups" through a pure
            // GroupSession value — AppState's ingestEvent applies the
            // side effect (drop the group + show notice) for non-author
            // peers. Returning nil here is a no-op in the reducer's
            // local-state merge path.
            return nil
        }
    }
}

//
//  LocalGroupService.swift
//  GroupIn
//
//  In-memory implementation of CloudKitServicing for local development.
//  Persists the groups dictionary to UserDefaults so invite codes survive
//  app relaunches. Swap this out for a real CloudKit-backed implementation
//  later — ViewModels won't need to change.
//

import Foundation

enum GroupServiceError: LocalizedError {
    case invalidName
    case invalidCode
    case groupNotFound
    case noPendingExtension
    /// The local user has been banned from this group by its owner.
    /// Surface a recovery path: ask the owner to invite them again.
    case banned

    var errorDescription: String? {
        switch self {
        case .invalidName:         return "Please enter a group name."
        case .invalidCode:         return "Please enter an invite code."
        case .groupNotFound:       return "No group matches that invite code."
        case .noPendingExtension:  return "There's no pending extension to accept."
        case .banned:              return "You were removed from this group. Ask the owner to invite you again."
        }
    }
}

@MainActor
final class LocalGroupService: CloudKitServicing {
    /// LocalGroupService only stores groups the local device created
    /// or already joined. No shared server-side store → no way to
    /// discover a remote group by invite code. JoinGroupViewModel
    /// reads this and falls back to BLE-only discovery.
    let supportsRemoteJoin = false

    private static let storageKey = "GroupIn.LocalGroupService.groups"
    private static let eventsKey = "GroupIn.LocalGroupService.events"
    /// Stable per-install identifier used for ban-hash computation in
    /// the local backend. Generated once and persisted; survives app
    /// relaunches but rotates on uninstall (the local backend exists
    /// for development only, so reinstall-rotation is acceptable).
    private static let installIDKey = "GroupIn.LocalGroupService.installID"

    private let defaults: UserDefaults
    private var groupsByCode: [String: GroupSession]
    /// In-memory event log keyed by groupID, persisted to UserDefaults
    /// so the local backend behaves like CloudKit for testing — events
    /// survive process restart, can be queried since cursor, etc.
    private var eventsByGroup: [UUID: [Event]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: GroupSession].self, from: data) {
            self.groupsByCode = decoded
        } else {
            self.groupsByCode = [:]
        }
        if let data = defaults.data(forKey: Self.eventsKey),
           let decoded = try? JSONDecoder().decode([UUID: [Event]].self, from: data) {
            self.eventsByGroup = decoded
        }
    }

    // MARK: - Create / Join

    func saveGroup(_ group: GroupSession) async throws {
        // Same offline-first semantics as the CloudKit backend —
        // caller already minted the GroupSession's identity; we just
        // persist it. Idempotent on invite code: a re-save of the
        // same group overwrites the existing entry rather than
        // duplicating.
        groupsByCode[group.inviteCode] = group
        save()
    }

    func fetchGroup(groupID: UUID) async throws -> GroupSession? {
        groupsByCode.values.first { $0.id == groupID }
    }

    func joinGroup(inviteCode: String) async throws -> GroupSession {
        let normalized = inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { throw GroupServiceError.invalidCode }
        guard let group = groupsByCode[normalized] else {
            throw GroupServiceError.groupNotFound
        }
        return group
    }

    func publish(user: User, in group: GroupSession) async throws {
        guard var stored = groupsByCode[group.inviteCode] else {
            throw GroupServiceError.groupNotFound
        }
        if let idx = stored.members.firstIndex(where: { $0.id == user.id }) {
            stored.members[idx] = user
        } else {
            stored.members.append(user)
        }
        groupsByCode[group.inviteCode] = stored
        save()
    }

    // MARK: - Expiry / extension

    func proposeExtension(groupID: UUID,
                         newExpiresAt: Date) async throws -> GroupSession {
        guard var group = findGroup(id: groupID) else {
            throw GroupServiceError.groupNotFound
        }
        group.pendingExtension = PendingExtension(
            newExpiresAt: newExpiresAt,
            proposedAt: .now,
            acceptedMemberIDs: []
        )
        groupsByCode[group.inviteCode] = group
        save()
        return group
    }

    func acceptExtension(groupID: UUID,
                        memberID: UUID) async throws -> GroupSession {
        guard var group = findGroup(id: groupID) else {
            throw GroupServiceError.groupNotFound
        }
        guard var pending = group.pendingExtension else {
            throw GroupServiceError.noPendingExtension
        }
        if !pending.acceptedMemberIDs.contains(memberID) {
            pending.acceptedMemberIDs.append(memberID)
        }
        group.pendingExtension = pending
        groupsByCode[group.inviteCode] = group
        save()
        return group
    }

    func resolveExpiry(groupID: UUID) async throws -> GroupSession? {
        guard var group = findGroup(id: groupID) else { return nil }

        if let pending = group.pendingExtension {
            // Keep owner + members who explicitly accepted.
            group.members = group.members.filter { member in
                member.id == group.ownerID || pending.acceptedMemberIDs.contains(member.id)
            }
            group.expiresAt = pending.newExpiresAt
            group.pendingExtension = nil
            groupsByCode[group.inviteCode] = group
            save()
            return group
        } else {
            // Hard delete.
            groupsByCode.removeValue(forKey: group.inviteCode)
            save()
            return nil
        }
    }

    // MARK: - Subscriptions (no-ops for the in-memory backend)

    func subscribeToPresenceUpdates(groupID: UUID) async throws {
        // Local backend has no server-side push; nothing to do.
    }

    func unsubscribeFromPresenceUpdates(groupID: UUID) async throws {
        // Local backend has no server-side push; nothing to do.
    }

    func deleteGroup(groupID: UUID) async throws {
        // Wipe from in-memory storage. Mirrors the cloud delete behavior
        // so swipe-remove feels symmetric across backends.
        if let key = groupsByCode.first(where: { $0.value.id == groupID })?.key {
            groupsByCode.removeValue(forKey: key)
            save()
        }
    }

    func iCloudAccountStatus() async -> ICloudAccountStatus {
        // Local backend doesn't depend on iCloud, so always green.
        .available
    }

    func removeMember(memberID: UUID,
                      fromGroup groupID: UUID) async throws -> GroupSession {
        guard let key = groupsByCode.first(where: { $0.value.id == groupID })?.key,
              var group = groupsByCode[key] else {
            throw GroupServiceError.groupNotFound
        }
        // Snapshot the kicked member's banHash + display name before
        // we drop them from the members list, so the banlist entry is
        // populated correctly.
        if let kicked = group.members.first(where: { $0.id == memberID }),
           let hash = kicked.banHash,
           !group.bannedMembers.contains(where: { $0.banHash == hash }) {
            group.bannedMembers.append(BannedMember(
                banHash: hash,
                displayName: kicked.displayName,
                bannedAt: .now
            ))
        }
        group.members.removeAll { $0.id == memberID }
        groupsByCode[key] = group
        save()
        return group
    }

    func leaveGroup(groupID: UUID,
                    memberID: UUID) async throws {
        guard let key = groupsByCode.first(where: { $0.value.id == groupID })?.key,
              var group = groupsByCode[key] else {
            // Already gone — treat as success (idempotent).
            return
        }
        group.members.removeAll { $0.id == memberID }
        groupsByCode[key] = group
        save()
    }

    func unbanMember(banHash: String,
                     fromGroup groupID: UUID) async throws -> GroupSession {
        guard let key = groupsByCode.first(where: { $0.value.id == groupID })?.key,
              var group = groupsByCode[key] else {
            throw GroupServiceError.groupNotFound
        }
        group.bannedMembers.removeAll { $0.banHash == banHash }
        groupsByCode[key] = group
        save()
        return group
    }

    func cloudUserID() async -> String? {
        // Stable per-install ID. Created lazily on first call and
        // persisted in UserDefaults so re-runs share the same value.
        if let existing = defaults.string(forKey: Self.installIDKey) {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: Self.installIDKey)
        return new
    }

    // MARK: - Event log

    func appendEvent(_ event: Event) async throws {
        var log = eventsByGroup[event.groupID] ?? []
        // Idempotent on event ID — a duplicate append (e.g. from a
        // retry) is a no-op rather than producing two entries.
        guard !log.contains(where: { $0.id == event.id }) else { return }
        log.append(event)
        eventsByGroup[event.groupID] = log
        saveEvents()
    }

    func fetchEvents(forGroupID groupID: UUID,
                     since cursor: EventCursor?) async throws -> [Event] {
        let log = eventsByGroup[groupID] ?? []
        guard let cursor else { return log }
        return log.filter { event in
            if event.createdAt != cursor.createdAt {
                return event.createdAt > cursor.createdAt
            }
            return event.id.uuidString > cursor.id.uuidString
        }
    }

    func fetchEvents(forGroupID groupID: UUID,
                     olderThan cursor: EventCursor?,
                     limit: Int) async throws -> [Event] {
        let log = eventsByGroup[groupID] ?? []
        let filtered: [Event]
        if let cursor {
            filtered = log.filter { event in
                if event.createdAt != cursor.createdAt {
                    return event.createdAt < cursor.createdAt
                }
                return event.id.uuidString < cursor.id.uuidString
            }
        } else {
            filtered = log
        }
        // Sort descending (newest first), then take the first `limit`.
        // That keeps semantics aligned with the CloudKit backend.
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        return Array(sorted.prefix(limit))
    }

    func subscribeToEvents(groupID: UUID) async throws {
        // Local backend has no push delivery; nothing to do.
    }

    func unsubscribeFromEvents(groupID: UUID) async throws {
        // Local backend has no push delivery; nothing to do.
    }

    // MARK: - Helpers

    private func findGroup(id: UUID) -> GroupSession? {
        groupsByCode.values.first(where: { $0.id == id })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groupsByCode) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func saveEvents() {
        // Strip avatar payloads before persisting — see the matching
        // comment in AppState.persistEventsByGroup. Avatars live on
        // the User record and don't need to be duplicated inside
        // every memberJoined event written to UserDefaults; doing so
        // blows past the 4 MB platform ceiling once a group has a
        // few photo-bearing joins.
        let stripped = eventsByGroup.mapValues { events in
            events.map { $0.strippedForBLE() }
        }
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Self.eventsKey)
        }
    }

}

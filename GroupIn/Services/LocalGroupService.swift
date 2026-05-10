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
    private static let storageKey = "GroupIn.LocalGroupService.groups"
    /// Stable per-install identifier used for ban-hash computation in
    /// the local backend. Generated once and persisted; survives app
    /// relaunches but rotates on uninstall (the local backend exists
    /// for development only, so reinstall-rotation is acceptable).
    private static let installIDKey = "GroupIn.LocalGroupService.installID"

    private let defaults: UserDefaults
    private var groupsByCode: [String: GroupSession]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: GroupSession].self, from: data) {
            self.groupsByCode = decoded
        } else {
            self.groupsByCode = [:]
        }
    }

    // MARK: - Create / Join

    func createGroup(named name: String,
                     category: GroupCategory,
                     ownerID: UUID,
                     expiresAt: Date) async throws -> GroupSession {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupServiceError.invalidName }

        let code = Self.generateInviteCode()
        let group = GroupSession(name: trimmed,
                                 inviteCode: code,
                                 category: category,
                                 ownerID: ownerID,
                                 expiresAt: expiresAt)
        groupsByCode[code] = group
        save()
        return group
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

    // MARK: - Helpers

    private func findGroup(id: UUID) -> GroupSession? {
        groupsByCode.values.first(where: { $0.id == id })
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groupsByCode) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // Excludes ambiguous characters (0/O, 1/I) for easier verbal sharing.
    private static func generateInviteCode(length: Int = 6) -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

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

    var errorDescription: String? {
        switch self {
        case .invalidName:    return "Please enter a group name."
        case .invalidCode:    return "Please enter an invite code."
        case .groupNotFound:  return "No group matches that invite code."
        }
    }
}

@MainActor
final class LocalGroupService: CloudKitServicing {
    private static let storageKey = "GroupIn.LocalGroupService.groups"

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

    func createGroup(named name: String) async throws -> GroupSession {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupServiceError.invalidName }

        let code = Self.generateInviteCode()
        let group = GroupSession(name: trimmed, inviteCode: code)
        groupsByCode[code] = group
        save()
        return group
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

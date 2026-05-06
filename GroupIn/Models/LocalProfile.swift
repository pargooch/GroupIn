//
//  LocalProfile.swift
//  GroupIn
//
//  The device-side profile. Lives only on this device — never synced.
//  When the user creates or joins a group, a fresh per-group `User` is
//  built from this profile (with a brand-new UUID), so memberships
//  across groups can't be linked. Editing the profile propagates the
//  display name and avatar into existing memberships.
//

import Foundation

struct LocalProfile: Codable, Equatable {
    var displayName: String
    var avatarData: Data?

    static let `default` = LocalProfile(displayName: "", avatarData: nil)

    /// True until the user picks a real name. The "User" check covers
    /// existing installs from before onboarding was required.
    var needsOnboarding: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "User"
    }
}

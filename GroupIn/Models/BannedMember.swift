//
//  BannedMember.swift
//  GroupIn
//
//  An entry in a group's owner-managed banlist. Stored on the Group
//  CKRecord as parallel String/Date arrays so the public-database
//  schema stays in primitives. The `banHash` is a per-group salted
//  digest of the iCloud user identifier — opaque to other members,
//  not correlatable across groups.
//

import Foundation
import CryptoKit

struct BannedMember: Identifiable, Hashable, Codable, Sendable {
    /// Stable per-(iCloud-account, group) identifier. Computed via
    /// `BanHash.compute(cloudUserID:inviteCode:)`.
    let banHash: String
    /// Snapshot of the member's display name at ban time. Used purely
    /// for the owner's "Banned members" list — the actual ban check
    /// is on `banHash`.
    let displayName: String
    let bannedAt: Date

    var id: String { banHash }
}

/// Pure-function computation of the per-group ban hash. Pulled out of
/// AppState/CloudKitService so it's trivially testable and identical
/// across backends.
enum BanHash {
    /// SHA-256 hex of `<cloudUserID>:<UPPERCASE_INVITE_CODE>`. The
    /// invite-code salt is what keeps the hash from being correlatable
    /// across groups: the same iCloud account in two different groups
    /// produces two unrelated hashes.
    static func compute(cloudUserID: String, inviteCode: String) -> String {
        let normalized = inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let payload = "\(cloudUserID):\(normalized)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

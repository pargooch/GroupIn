//
//  GroupSession.swift
//  GroupIn
//

import Foundation

/// In-flight extension proposed by the owner. At the original `expiresAt`,
/// members not in `acceptedMemberIDs` (and who aren't the owner) are removed,
/// the group's `expiresAt` advances to `newExpiresAt`, and this struct clears.
struct PendingExtension: Codable, Hashable {
    var newExpiresAt: Date
    var proposedAt: Date
    var acceptedMemberIDs: [UUID]
}

struct GroupSession: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var inviteCode: String
    var category: GroupCategory
    var createdAt: Date
    var members: [User]
    let ownerID: UUID
    var expiresAt: Date
    var pendingExtension: PendingExtension?
    /// Owner-managed banlist. Stored as a list of `BannedMember`
    /// entries so the dashboard can show "Alice (banned 2 days ago)"
    /// without leaking any cross-group identity. New groups default
    /// to empty and old persisted/CloudKit records decode safely.
    var bannedMembers: [BannedMember]

    init(id: UUID = UUID(),
         name: String,
         inviteCode: String,
         category: GroupCategory = .other,
         ownerID: UUID,
         expiresAt: Date,
         createdAt: Date = .now,
         members: [User] = [],
         pendingExtension: PendingExtension? = nil,
         bannedMembers: [BannedMember] = []) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.category = category
        self.ownerID = ownerID
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.members = members
        self.pendingExtension = pendingExtension
        self.bannedMembers = bannedMembers
    }

    /// Custom decoder so old persisted groups (no `category` /
    /// `bannedMembers` fields) decode gracefully with sensible defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.inviteCode = try c.decode(String.self, forKey: .inviteCode)
        self.category = (try? c.decode(GroupCategory.self, forKey: .category)) ?? .other
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.members = try c.decode([User].self, forKey: .members)
        self.ownerID = try c.decode(UUID.self, forKey: .ownerID)
        self.expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        self.pendingExtension = try? c.decode(PendingExtension.self, forKey: .pendingExtension)
        self.bannedMembers = (try? c.decode([BannedMember].self, forKey: .bannedMembers)) ?? []
    }

    var isExpired: Bool { expiresAt <= .now }

    var hasPendingExtension: Bool { pendingExtension != nil }

    func isOwner(_ memberID: UUID) -> Bool { ownerID == memberID }

    /// Random invite code. Lifted out of the CloudKit service so the
    /// offline-first creation path (CreateGroupViewModel) can mint a
    /// complete GroupSession in-process without a CloudKit dependency.
    /// Alphabet excludes ambiguous characters (`0/O`, `1/I`) so the
    /// code is easier to share verbally.
    ///
    /// Length is 16 because the invite code doubles as the end-to-end
    /// encryption secret (the group key is `HKDF(code)`), and its
    /// SHA-256 hash is stored in the public CloudKit DB for lookup. A
    /// short code could be brute-forced from that hash and used to
    /// derive the key, so we need real entropy: 16 × ~5 bits ≈ 80 bits,
    /// which is infeasible to brute-force. Sharing is via QR / copy /
    /// share-sheet; verbal sharing of a 16-char code isn't the path.
    static func generateInviteCode(length: Int = 16) -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        var rng = SystemRandomNumberGenerator()  // CSPRNG on Apple platforms
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// True if `memberID` has accepted the current pending extension
    /// (or is the owner, who's an implicit accept).
    func hasAcceptedExtension(_ memberID: UUID) -> Bool {
        guard let pending = pendingExtension else { return false }
        return memberID == ownerID || pending.acceptedMemberIDs.contains(memberID)
    }
}

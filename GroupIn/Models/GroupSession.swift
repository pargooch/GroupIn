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
    var createdAt: Date
    var members: [User]
    let ownerID: UUID
    var expiresAt: Date
    var pendingExtension: PendingExtension?

    init(id: UUID = UUID(),
         name: String,
         inviteCode: String,
         ownerID: UUID,
         expiresAt: Date,
         createdAt: Date = .now,
         members: [User] = [],
         pendingExtension: PendingExtension? = nil) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.ownerID = ownerID
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.members = members
        self.pendingExtension = pendingExtension
    }

    var isExpired: Bool { expiresAt <= .now }

    var hasPendingExtension: Bool { pendingExtension != nil }

    func isOwner(_ memberID: UUID) -> Bool { ownerID == memberID }

    /// True if `memberID` has accepted the current pending extension
    /// (or is the owner, who's an implicit accept).
    func hasAcceptedExtension(_ memberID: UUID) -> Bool {
        guard let pending = pendingExtension else { return false }
        return memberID == ownerID || pending.acceptedMemberIDs.contains(memberID)
    }
}

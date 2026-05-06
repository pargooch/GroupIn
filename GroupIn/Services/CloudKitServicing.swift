//
//  CloudKitServicing.swift
//  GroupIn
//
//  The contract that any group backend must satisfy. `LocalGroupService`
//  is the in-memory implementation; `CloudKitService` is the real one.
//  ViewModels and AppState only depend on this protocol, so swapping
//  backends is a one-line change at the App entry point.
//

import Foundation

protocol CloudKitServicing {
    func createGroup(named name: String,
                     ownerID: UUID,
                     expiresAt: Date) async throws -> GroupSession

    func joinGroup(inviteCode: String) async throws -> GroupSession

    /// Re-fetches the latest group state including member list. Returns nil
    /// if the group has been deleted server-side.
    func fetchGroup(groupID: UUID) async throws -> GroupSession?

    func publish(user: User, in group: GroupSession) async throws

    /// Owner proposes a new expiry. Members must accept by the *original*
    /// expiry to stay; otherwise they're removed when that time hits.
    func proposeExtension(groupID: UUID,
                         newExpiresAt: Date) async throws -> GroupSession

    /// A member accepts the currently-pending extension.
    func acceptExtension(groupID: UUID,
                        memberID: UUID) async throws -> GroupSession

    /// Resolves the current expiry on a group:
    /// - If `pendingExtension` is set, applies it (filtering members,
    ///   advancing `expiresAt`, clearing the pending state). Returns the
    ///   updated group.
    /// - If no extension, hard-deletes the group. Returns `nil`.
    func resolveExpiry(groupID: UUID) async throws -> GroupSession?
}

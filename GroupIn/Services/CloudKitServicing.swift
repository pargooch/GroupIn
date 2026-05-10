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

/// Backend-agnostic mirror of `CKAccountStatus` plus the local-dev case
/// where iCloud isn't applicable at all. Used by AppState to surface a
/// single banner whether the active backend is CloudKit or the local
/// dev stub.
enum ICloudAccountStatus: Sendable, Equatable {
    /// Signed in and ready to use. Includes the LocalGroupService case
    /// where iCloud isn't required at all.
    case available
    /// User is signed out. Surface a "sign into iCloud in Settings" banner.
    case noAccount
    /// MDM / parental restriction.
    case restricted
    /// CloudKit hasn't replied yet, or temporarily unreachable.
    case couldNotDetermine
    /// iCloud account in a transient bad state (e.g. account just changed
    /// and CloudKit hasn't finished re-priming).
    case temporarilyUnavailable
}

@MainActor
protocol CloudKitServicing: AnyObject {
    func createGroup(named name: String,
                     category: GroupCategory,
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

    /// Register a server-side subscription that fires a silent push
    /// whenever any member record in the given group is created or
    /// updated. Replaces the 10-second polling refresh with near-instant
    /// notifications.
    func subscribeToPresenceUpdates(groupID: UUID) async throws

    /// Tear down the subscription created by
    /// `subscribeToPresenceUpdates(groupID:)`. Call when the user leaves
    /// the group so we don't accumulate stale subscriptions server-side.
    func unsubscribeFromPresenceUpdates(groupID: UUID) async throws

    /// Owner-initiated hard delete. Removes the group record + cascading
    /// member records from the backend. Distinct from `resolveExpiry`,
    /// which handles natural expiration with potential extensions; this
    /// is what swipe-remove on the owner's home list calls.
    func deleteGroup(groupID: UUID) async throws

    /// Quick health check the app does at launch (and again whenever the
    /// system fires `CKAccountChanged`). Returns the user-visible state
    /// so AppState can put up a "sign in to iCloud" banner before any
    /// group action ever fails.
    func iCloudAccountStatus() async -> ICloudAccountStatus
}

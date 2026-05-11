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
    /// Persists a fully-constructed `GroupSession`. The caller is
    /// expected to mint the GroupSession locally (via
    /// `GroupSession.generateInviteCode` + a fresh UUID + the user-
    /// supplied name/category/expiry) and then hand it here for
    /// durable storage. Throws on transport / quota / schema errors —
    /// AppState catches the throw and queues the save for retry so
    /// group creation remains usable offline.
    func saveGroup(_ group: GroupSession) async throws

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

    /// Owner kicks a single member out of the group. The member's
    /// record is deleted server-side and their `banHash` is appended
    /// to the group's banlist so they can't rejoin with the same
    /// invite code. Returns the freshly-fetched group so the UI can
    /// reconcile immediately.
    func removeMember(memberID: UUID,
                      fromGroup groupID: UUID) async throws -> GroupSession

    /// A member voluntarily leaves the group. Deletes their member
    /// record server-side without touching the banlist — they can
    /// rejoin freely with the invite code. Distinct from
    /// `removeMember`, which is owner-initiated and bans.
    func leaveGroup(groupID: UUID,
                    memberID: UUID) async throws

    /// Owner reverses a ban. The entry is removed from the group's
    /// banlist; the previously-banned user can now rejoin with the
    /// invite code as if they'd never been removed.
    func unbanMember(banHash: String,
                     fromGroup groupID: UUID) async throws -> GroupSession

    /// Stable, anonymous identifier for the local user — `recordName`
    /// of `CKContainer.userRecordID()` for the CloudKit backend, or a
    /// per-install UUID for the local stub. Used to compute the
    /// per-group ban hash. Returns nil if the user isn't signed into
    /// iCloud (or the backend is offline) — callers should treat that
    /// as "ban enforcement unavailable" and degrade gracefully.
    func cloudUserID() async -> String?

    /// Quick health check the app does at launch (and again whenever the
    /// system fires `CKAccountChanged`). Returns the user-visible state
    /// so AppState can put up a "sign in to iCloud" banner before any
    /// group action ever fails.
    func iCloudAccountStatus() async -> ICloudAccountStatus

    // MARK: - Event log (Path C)

    /// Append a single event to the group's append-only log. Events
    /// are immutable once written — corrections are themselves new
    /// events (e.g. `memberUnbanned` cancels `memberRemoved`).
    func appendEvent(_ event: Event) async throws

    /// Fetch all events for a group strictly newer than `cursor`. Used
    /// for cold-start replay (cursor = nil → entire log) and for
    /// incremental sync after a silent push lands. Caller sorts and
    /// folds the result via `EventReducer`.
    func fetchEvents(forGroupID groupID: UUID,
                     since cursor: EventCursor?) async throws -> [Event]

    /// Fetch a paginated batch of events strictly **older** than
    /// `cursor`, capped at `limit`. Used for scroll-to-top history
    /// loading: the UI requests "30 older than what I have now,"
    /// gets that batch, and updates its oldest-local-cursor. If
    /// `cursor` is nil, returns the most recent `limit` events
    /// (first-open seed). When the returned count is less than
    /// `limit`, we've reached the start of the group's history.
    func fetchEvents(forGroupID groupID: UUID,
                     olderThan cursor: EventCursor?,
                     limit: Int) async throws -> [Event]

    /// Register a CloudKit silent push subscription for new events in
    /// this group. Fires on Event record creation; AppState's push
    /// handler consumes it and triggers an incremental fetch.
    /// Separate from `subscribeToPresenceUpdates` — moderation events
    /// shouldn't share a notification channel with high-frequency
    /// presence updates so we can tune throttling independently.
    func subscribeToEvents(groupID: UUID) async throws

    /// Tear down the Event subscription. Called from
    /// `reconcileTrackingLifecycle` when a group leaves `myGroups`.
    func unsubscribeFromEvents(groupID: UUID) async throws
}

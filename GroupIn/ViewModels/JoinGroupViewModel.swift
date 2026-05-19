//
//  JoinGroupViewModel.swift
//  GroupIn
//
//  Fully-offline, nearby-only join. The flow:
//
//   1. User enters or scans the invite code.
//   2. We start BLE join-discovery: scan for in-range peers, write
//      a JoinRequest to anyone advertising our service.
//   3. When a host with a matching invite code responds (over BLE
//      GATT notify), we materialize their JoinResponse into a local
//      `GroupSession`, register membership, navigate to the dashboard,
//      and emit a `memberJoined` event so the host's gossip + our
//      local log converge.
//   4. If no response arrives within `discoveryTimeout`, we surface
//      a clear "no nearby host" error with retry.
//
//  Design intent — make every state transition explicit and ordered.
//  No racing tasks, no withTaskGroup, no CloudKit fallback. One task,
//  one path, one user-visible outcome.
//

import Foundation
import Observation

@MainActor
@Observable
final class JoinGroupViewModel {
    var inviteCode: String = ""
    var isSubmitting: Bool = false
    /// User-visible error. Cleared on every new join attempt + every
    /// edit of the invite code. The view shows it in a banner above
    /// the join button.
    var errorMessage: String?
    /// In-flight status message. Drives the spinner row when
    /// `isSubmitting` is true.
    var statusMessage: String?

    private let appState: AppState

    /// Active join task. Cancelled by `cancel()` or by `joinGroup()`
    /// itself when a new attempt supersedes the prior one. Held so
    /// `cancel()` can tear down the BLE discovery immediately.
    private var activeTask: Task<Void, Never>?

    /// Joiner identity for this view-model session. We cache it on
    /// first attempt and reuse on every retry — the host dedups
    /// `JoinRequest`s by `joinerMemberID` in `commitJoinerLocally`,
    /// so if every retry minted a new UUID the host would happily
    /// commit you as a brand-new member each tap (causing the
    /// "duplications" bug). Cleared when the join ultimately
    /// succeeds or the screen disappears.
    private var sessionJoiner: User?

    /// Discovery deadline. Beyond this, we give up and surface
    /// "no nearby host." 30 seconds is comfortable for a real-room
    /// scan — long enough that a host walking back from the bathroom
    /// can still answer, short enough that we don't strand the user
    /// in an infinite spinner.
    private static let discoveryTimeout: TimeInterval = 30

    init(appState: AppState) {
        self.appState = appState
    }

    var canSubmit: Bool {
        !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    // MARK: - Entry points

    func joinGroup() async {
        // Supersede any earlier in-flight attempt — fresh tap, fresh
        // task. Without this an impatient user could stack 5 BLE
        // discovery tasks by tapping Join repeatedly.
        activeTask?.cancel()

        let trimmed = inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a group invite code first."
            return
        }
        inviteCode = trimmed

        errorMessage = nil
        statusMessage = "Looking for nearby host…"
        isSubmitting = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runJoinAttempt(inviteCode: trimmed)
        }
        activeTask = task
        await task.value
    }

    /// User-initiated cancel from the Cancel button. Tears down the
    /// active task and BLE discovery, clears the spinner, leaves the
    /// invite code populated so the user can retry without retyping.
    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        appState.cancelBLEJoinDiscovery()
        isSubmitting = false
        statusMessage = nil
    }

    // MARK: - Core flow

    private func runJoinAttempt(inviteCode: String) async {
        defer {
            // Always clean up on exit — task ending normally,
            // throwing, or cancelled. Without this defer a thrown
            // path could leave `isSubmitting = true` forever.
            if !Task.isCancelled {
                isSubmitting = false
                statusMessage = nil
            }
            appState.cancelBLEJoinDiscovery()
        }

        // Quick local-side ban check before even broadcasting — if
        // we already know we're banned (we have a cached cloud ID
        // and the group has us in its banlist), refuse early. This
        // doesn't catch the case where we don't have a banHash yet;
        // the responder's check covers that.
        // (Performed inside `awaitBLEJoinResponse` once we have the
        // response too — defense in depth.)

        let joiner: User
        if let cached = sessionJoiner {
            joiner = cached
        } else {
            let fresh = appState.makeMembership()
            sessionJoiner = fresh
            joiner = fresh
        }

        let response: JoinResponse?
        do {
            response = try await withTimeout(seconds: Self.discoveryTimeout) {
                await self.appState.awaitBLEJoinResponse(
                    forInviteCode: inviteCode,
                    joiner: joiner
                )
            }
        } catch is TimeoutError {
            // No host answered within the discovery window.
            errorMessage = "No nearby host found with this code. " +
                "Make sure the host's phone is unlocked, GroupIn is open, " +
                "and you're within Bluetooth range."
            return
        } catch {
            // Cancellation lands here too (CancellationError). Don't
            // surface an error message — the cancel button cleared
            // state already.
            return
        }

        guard let response else {
            // BLE discovery returned nil without throwing — discovery
            // stopped (e.g. group teardown), surface generic message.
            errorMessage = "Couldn't connect to a nearby host. Try again."
            return
        }

        if Task.isCancelled { return }
        await applyJoinResponse(response, joiner: joiner)
    }

    /// Materialize a JoinResponse received over BLE into a local
    /// GroupSession, register membership, navigate. Mirrors the
    /// host's `commitJoinerLocally` — the deterministic
    /// `memberJoinedEventID` collapses our emit against theirs at
    /// ingest so the timeline shows one "X joined" row, not two.
    private func applyJoinResponse(_ response: JoinResponse, joiner: User) async {
        guard var group = response.toGroupSession() else {
            errorMessage = "The host's response was malformed. Try again."
            return
        }

        if appState.isLocalUserBanned(from: group) {
            errorMessage = GroupServiceError.banned.localizedDescription
            return
        }

        var me = joiner
        me = appState.stampBanHash(me, for: group)
        if !group.members.contains(where: { $0.id == me.id }) {
            group.members.append(me)
        }

        appState.registerMembership(groupID: group.id, memberID: me.id)
        appState.addOrUpdate(group: group)
        appState.currentUser = me
        appState.currentGroup = group

        // Persist the group via the backend too — without this,
        // LocalGroupService doesn't have a record of this group
        // (we only know about it because the host gave us a
        // JoinResponse over BLE), and subsequent calls into
        // `groupService.fetchGroup(groupID:)` return nil. The
        // CloudKit backend's saveGroup is idempotent on group ID, so
        // re-saving on the joiner side is harmless when CloudKit is on.
        appState.dispatchGroupSave(group)

        // Dispatch the member publish via the persisted retry queue —
        // when CloudKit comes back online (or stays off forever in
        // pure-offline mode), the queue carries the side-effect
        // semantics. Local LocalGroupService just persists immediately.
        appState.dispatchMemberPublish(me, in: group)

        // Emit memberJoined with the deterministic ID so this collapses
        // against the host's matching emit at ingest dedup.
        let eventID = Event.memberJoinedEventID(
            groupID: group.id,
            memberID: me.id
        )
        let event = Event(
            id: eventID,
            groupID: group.id,
            authorID: me.id,
            createdAt: .now,
            payload: .memberJoined(
                memberID: me.id,
                displayName: me.displayName,
                avatarData: me.avatarData,
                banHash: me.banHash
            )
        )
        appState.emit(event)

        // Joined — clear the cached joiner so a future trip to this
        // screen mints a fresh identity.
        sessionJoiner = nil

        // Defer the navigation pop to a separate runloop tick. The
        // burst of @Observable mutations above (membership,
        // currentUser, currentGroup, addOrUpdate, emit, dispatchGroupSave)
        // all fire in one synchronous tick — letting SwiftUI fully
        // settle the resulting render before we yank the navigation
        // stack out from under JoinGroupView removes a class of
        // ordering hazards (onDisappear cancelling a still-finishing
        // task, view-tree diff against half-mutated state, etc).
        Task { @MainActor in
            await Task.yield()
            appState.path.removeAll()
        }
    }

    // MARK: - Timeout primitive

    private struct TimeoutError: Error {}

    /// Race the operation against a sleep. First to finish wins;
    /// the loser is cancelled. Cancellation propagates from the
    /// caller (e.g. `cancel()` cancelling `activeTask`) through
    /// `withTaskGroup` to each child.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            // First child wins. Cancel the rest so they don't dangle.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

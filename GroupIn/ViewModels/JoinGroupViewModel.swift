//
//  JoinGroupViewModel.swift
//  GroupIn
//

import Foundation
import Observation

@MainActor
@Observable
final class JoinGroupViewModel {
    var inviteCode: String = ""
    var isSubmitting: Bool = false
    /// Hard error to show to the user — only set for problems they
    /// can actually do something about (wrong code, banned, not
    /// signed into iCloud). Transient errors silently retry instead.
    var errorMessage: String?
    /// In-flight status message for the user during silent retries.
    /// Nil when idle; "Looking for group..." while we're cycling
    /// through retry attempts behind the scenes.
    var statusMessage: String?

    private let appState: AppState

    /// Cap the silent-retry backoff. Beyond this, each retry waits
    /// the same interval — we never give up entirely, but we don't
    /// keep doubling forever either. The user can cancel by tapping
    /// out of the join screen.
    private static let maxRetryDelay: TimeInterval = 30

    init(appState: AppState) {
        self.appState = appState
    }

    var canSubmit: Bool {
        !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    func joinGroup() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil
        defer {
            isSubmitting = false
            statusMessage = nil
        }

        let service = appState.groupService
        let code = inviteCode

        statusMessage = "Looking for group…"

        // Race two paths in parallel:
        //   1. CloudKit join — retries transient errors silently.
        //   2. BLE discovery — asks any in-range peer "do you have a
        //      group with this invite code?" via the joinRequest /
        //      joinResponse handshake.
        // Whichever resolves first wins; the other is cancelled. BLE
        // discovery is uniquely useful when CloudKit is unreachable
        // OR when the host's group save is still queued (so the cloud
        // hasn't seen it yet but a member in BLE range has).
        await withTaskGroup(of: JoinAttemptResult.self) { group in
            group.addTask { @MainActor [appState = appState] in
                let joiner = appState.makeMembership()
                if let response = await appState.awaitBLEJoinResponse(
                    forInviteCode: code, joiner: joiner
                ) {
                    return .bleResolved(response, joiner)
                }
                return .transient
            }
            group.addTask { @MainActor [self, service, code] in
                var delay: TimeInterval = 2
                while !Task.isCancelled {
                    let outcome = await self.attemptJoin(service: service, inviteCode: code)
                    switch outcome {
                    case .succeeded, .hardError, .bleResolved:
                        return outcome
                    case .transient:
                        try? await Task.sleep(for: .seconds(delay))
                        delay = min(Self.maxRetryDelay, delay * 2)
                    }
                }
                return .transient
            }

            // Accept the first authoritative answer (success / hard
            // error / BLE-resolved) and cancel the other task.
            while let result = await group.next() {
                switch result {
                case .succeeded:
                    group.cancelAll()
                    return
                case .hardError(let message):
                    errorMessage = message
                    group.cancelAll()
                    return
                case .bleResolved(let response, let joiner):
                    await applyBLEJoin(response: response, joiner: joiner)
                    group.cancelAll()
                    return
                case .transient:
                    // Loop — the other task may still resolve.
                    continue
                }
            }
        }
    }

    /// Apply a BLE-derived JoinResponse: mint the local GroupSession,
    /// stamp the joiner's ban hash, update AppState, navigate to the
    /// dashboard. The actual member publish + memberJoined event use
    /// the standard `emit` pipeline so cloud + BLE gossip both see
    /// the new member.
    private func applyBLEJoin(response: JoinResponse, joiner: User) async {
        guard var group = response.toGroupSession() else { return }

        // Ban gate at the joiner side too — defense in depth in case
        // the responder skipped its check.
        if appState.isLocalUserBanned(from: group) {
            errorMessage = GroupServiceError.banned.localizedDescription
            return
        }

        var me = joiner
        me = appState.stampBanHash(me, for: group)
        group.members.append(me)

        appState.registerMembership(groupID: group.id, memberID: me.id)
        appState.addOrUpdate(group: group)
        appState.currentUser = me
        appState.currentGroup = group
        appState.path.append(.groupDashboard(groupID: group.id))

        // Publish via standard pipeline. Cloud-side publish retries
        // via heartbeat; BLE event gossip handles the offline case.
        Task { [groupService = appState.groupService, me, group] in
            try? await groupService.publish(user: me, in: group)
        }
        appState.emit(
            .memberJoined(
                memberID: me.id,
                displayName: me.displayName,
                avatarData: me.avatarData,
                banHash: me.banHash
            ),
            in: group.id
        )
    }

    // MARK: - Inner attempt

    private enum JoinAttemptResult: Sendable {
        case succeeded
        case hardError(message: String)
        case transient
        /// BLE discovery returned a response — the calling code
        /// constructs the local GroupSession from this and the
        /// freshly-minted joiner User.
        case bleResolved(JoinResponse, User)
    }

    private func attemptJoin(service: CloudKitServicing,
                             inviteCode: String) async -> JoinAttemptResult {
        do {
            let group = try await service.joinGroup(inviteCode: inviteCode)

            // Pre-publish ban gate — refuse before writing a member
            // record so the banned user doesn't briefly appear on
            // the owner's dashboard.
            if appState.isLocalUserBanned(from: group) {
                return .hardError(message: GroupServiceError.banned.localizedDescription)
            }

            // Idempotent join: reuse existing membership ID if any.
            var me: User
            if let existingID = appState.membershipByGroupID[group.id] {
                me = User(
                    id: existingID,
                    displayName: appState.localProfile.displayName,
                    avatarData: appState.localProfile.avatarData
                )
            } else {
                me = appState.makeMembership()
            }
            me = appState.stampBanHash(me, for: group)

            // Local state first — user sees the dashboard immediately.
            var withMe = group
            if let idx = withMe.members.firstIndex(where: { $0.id == me.id }) {
                withMe.members[idx] = me
            } else {
                withMe.members.append(me)
            }
            appState.registerMembership(groupID: withMe.id, memberID: me.id)
            appState.addOrUpdate(group: withMe)
            appState.currentUser = me
            appState.currentGroup = withMe
            appState.path.append(.groupDashboard(groupID: withMe.id))

            // Publish in the background — heartbeat retries within
            // ~20 s if this loses a race.
            Task { [service, me, withMe] in
                try? await service.publish(user: me, in: withMe)
            }

            // Append `memberJoined` through the standard emit path so
            // it goes via pendingEmits (retried) + BLE gossip.
            appState.emit(
                .memberJoined(
                    memberID: me.id,
                    displayName: me.displayName,
                    avatarData: me.avatarData,
                    banHash: me.banHash
                ),
                in: withMe.id
            )

            return .succeeded
        } catch let error as GroupServiceError {
            // Service-level errors — most are user-fixable.
            switch error {
            case .invalidCode, .invalidName, .groupNotFound, .banned, .noPendingExtension:
                return .hardError(message: error.localizedDescription)
            }
        } catch let error as CloudKitError {
            switch error {
            case .notSignedIn:
                // User-fixable: they need to sign into iCloud.
                return .hardError(message: error.localizedDescription)
            case .schemaIncomplete:
                // Pseudo-transient: the schema may auto-deploy as
                // writes happen; meanwhile let the user know it's
                // a setup-side problem rather than retrying silently.
                return .hardError(message: error.localizedDescription)
            case .invalidRecord:
                return .hardError(message: error.localizedDescription)
            case .other:
                // Network blips, CloudKit unavailability, etc.
                return .transient
            }
        } catch {
            // Anything else — treat as transient. Worst case the
            // user sits on the loading state for a while and can
            // cancel out.
            return .transient
        }
    }
}

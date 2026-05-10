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
    var errorMessage: String?

    private let appState: AppState

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
        defer { isSubmitting = false }

        do {
            let service = appState.groupService
            let group = try await service.joinGroup(inviteCode: inviteCode)

            // Pre-publish ban gate. Refusing here (before we write a
            // member record) keeps the banned user from briefly
            // appearing in the group's member list on the owner's
            // dashboard. The banlist check is by salted hash, so
            // matches survive reinstall on the same iCloud account.
            if appState.isLocalUserBanned(from: group) {
                throw GroupServiceError.banned
            }

            // Idempotent join: if this device already has a membership ID
            // for this group, reuse it. Prevents duplicate member rows
            // when someone leaves and rejoins, or taps Join more than once.
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

            // Publish in the background so the navigation animation
            // overlaps with the network write. If the publish loses a
            // race (network blip), the heartbeat in AppState will
            // re-publish within ~20 s, so the joiner appears to other
            // members reliably without making them wait at the join
            // screen for the third network roundtrip.
            Task { [service, me, withMe] in
                try? await service.publish(user: me, in: withMe)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

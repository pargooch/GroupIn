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

            // Idempotent join: if this device already has a membership ID
            // for this group, reuse it. Prevents duplicate member rows
            // when someone leaves and rejoins, or taps Join more than once.
            let me: User
            if let existingID = appState.membershipByGroupID[group.id] {
                me = User(
                    id: existingID,
                    displayName: appState.localProfile.displayName,
                    avatarData: appState.localProfile.avatarData
                )
            } else {
                me = appState.makeMembership()
            }

            try await service.publish(user: me, in: group)

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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

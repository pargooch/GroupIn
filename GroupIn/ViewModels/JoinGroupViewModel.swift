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
            let me = appState.currentUser

            let group = try await service.joinGroup(inviteCode: inviteCode)
            try await service.publish(user: me, in: group)

            var withMe = group
            if !withMe.members.contains(where: { $0.id == me.id }) {
                withMe.members.append(me)
            }

            appState.addOrUpdate(group: withMe)
            appState.currentGroup = withMe
            appState.path.append(.groupDashboard(groupID: withMe.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

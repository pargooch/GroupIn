//
//  CreateGroupViewModel.swift
//  GroupIn
//

import Foundation
import Observation

@MainActor
@Observable
final class CreateGroupViewModel {
    var groupName: String = ""
    var isSubmitting: Bool = false
    var errorMessage: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var canSubmit: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    func createGroup() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let service = appState.groupService
            let creator = appState.currentUser

            let group = try await service.createGroup(named: groupName)
            try await service.publish(user: creator, in: group)

            var withCreator = group
            withCreator.members.append(creator)

            appState.addOrUpdate(group: withCreator)
            appState.currentGroup = withCreator
            appState.path.append(.groupDashboard(groupID: withCreator.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

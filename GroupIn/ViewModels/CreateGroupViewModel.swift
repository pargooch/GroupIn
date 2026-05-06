//
//  CreateGroupViewModel.swift
//  GroupIn
//

import Foundation
import Observation

enum GroupDuration: Hashable, CaseIterable, Identifiable {
    case oneHour
    case fourHours
    case twelveHours
    case oneDay
    case custom(TimeInterval)

    static var allCases: [GroupDuration] {
        [.oneHour, .fourHours, .twelveHours, .oneDay]
    }

    var id: TimeInterval { seconds }

    var seconds: TimeInterval {
        switch self {
        case .oneHour:     return 60 * 60
        case .fourHours:   return 60 * 60 * 4
        case .twelveHours: return 60 * 60 * 12
        case .oneDay:      return 60 * 60 * 24
        case .custom(let s): return s
        }
    }

    var label: String {
        switch self {
        case .oneHour:     return "1 hour"
        case .fourHours:   return "4 hours"
        case .twelveHours: return "12 hours"
        case .oneDay:      return "1 day"
        case .custom:      return "Custom"
        }
    }
}

@MainActor
@Observable
final class CreateGroupViewModel {
    var groupName: String = ""
    var duration: GroupDuration = .fourHours
    var customExpiresAt: Date = .now.addingTimeInterval(60 * 60 * 4)
    var useCustomDate: Bool = false
    var isSubmitting: Bool = false
    var errorMessage: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var canSubmit: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
            && resolvedExpiry > .now
    }

    var resolvedExpiry: Date {
        useCustomDate ? customExpiresAt : .now.addingTimeInterval(duration.seconds)
    }

    func createGroup() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let service = appState.groupService
            let me = appState.makeMembership()
            let expiresAt = resolvedExpiry

            let group = try await service.createGroup(
                named: groupName,
                ownerID: me.id,
                expiresAt: expiresAt
            )
            try await service.publish(user: me, in: group)

            var withCreator = group
            withCreator.members.append(me)

            appState.registerMembership(groupID: withCreator.id, memberID: me.id)
            appState.addOrUpdate(group: withCreator)
            appState.currentUser = me
            appState.currentGroup = withCreator
            appState.path.append(.groupDashboard(groupID: withCreator.id))

            // Fire the permission prompt + schedule T-30 reminder.
            // Detached so navigation isn't blocked by the system prompt.
            Task { [appState, withCreator] in
                await appState.registerNotifications(for: withCreator)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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
    var category: GroupCategory = .exploring {
        didSet {
            // Auto-suggest the category's default duration unless the user
            // has gone custom, in which case we leave their pick alone.
            if !useCustomDate {
                duration = category.defaultDuration
            }
        }
    }
    var duration: GroupDuration = GroupCategory.exploring.defaultDuration
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
            var me = appState.makeMembership()
            let expiresAt = resolvedExpiry

            let group = try await service.createGroup(
                named: groupName,
                category: category,
                ownerID: me.id,
                expiresAt: expiresAt
            )
            // Stamp the per-group ban hash now that we know the
            // invite code. Persisting it on the User record means
            // the owner has it on hand for their own future removal
            // operations (the owner can't ban themselves, but the
            // schema is uniform across roles).
            me = appState.stampBanHash(me, for: group)

            // Navigate immediately — the publish runs in the
            // background so the user doesn't sit on the create form
            // waiting for the third network roundtrip. Heartbeat
            // re-publishes within ~20 s if the initial write loses
            // a race, so members in the cloud see the owner reliably.
            var withCreator = group
            withCreator.members.append(me)

            appState.registerMembership(groupID: withCreator.id, memberID: me.id)
            appState.addOrUpdate(group: withCreator)
            appState.currentUser = me
            appState.currentGroup = withCreator
            appState.path.append(.groupDashboard(groupID: withCreator.id))

            Task { [service, me, withCreator] in
                try? await service.publish(user: me, in: withCreator)
            }

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

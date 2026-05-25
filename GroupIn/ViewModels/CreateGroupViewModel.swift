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

    /// Offline-first group creation.
    ///
    /// Generates the `GroupSession` in-process — UUID, invite code, all
    /// of it — without a network call. Local state updates and the
    /// user lands on the dashboard immediately. The CloudKit save is
    /// dispatched in the background; if it fails the save goes into
    /// `pendingGroupSaves` and the retry loop drains it once
    /// connectivity returns. From the user's perspective there's no
    /// "tap, wait, hope CloudKit responds" — group creation is
    /// instant whether they're online or in airplane mode.
    func createGroup() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let trimmedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Please enter a group name."
            return
        }

        let expiresAt = resolvedExpiry

        // Generate the invite code first so the membership ID can be
        // derived deterministically from it (stable across rejoins —
        // prevents duplicate "ghost" members).
        let inviteCode = GroupSession.generateInviteCode()
        var me = appState.makeMembership(forInviteCode: inviteCode)

        // Build the GroupSession entirely in-process. No service call,
        // no awaiting — local creation is synchronous and always
        // succeeds. The persisted CloudKit save is a separate concern
        // that AppState handles via its retry queue.
        let creationTime = Date()
        let group = GroupSession(
            id: UUID(),
            name: trimmedName,
            inviteCode: inviteCode,
            category: category,
            ownerID: me.id,
            expiresAt: expiresAt,
            createdAt: creationTime
        )

        // Stamp the per-group ban hash now that we know the invite
        // code. Persisting it on the User record means the owner has
        // it on hand for their own future removal operations.
        me = appState.stampBanHash(me, for: group)

        // Update local state immediately — group appears in
        // `myGroups`, membership map is registered, dashboard route
        // is pushed. The user is already at the dashboard by the
        // time the next line runs.
        var withCreator = group
        withCreator.members.append(me)
        appState.registerMembership(groupID: withCreator.id, memberID: me.id)
        appState.addOrUpdate(group: withCreator)
        appState.currentUser = me
        appState.currentGroup = withCreator
        appState.path.append(.groupDashboard(groupID: withCreator.id))

        // Hand the GroupSession to AppState for durable persistence.
        // Immediate attempt + retry-queue fallback all live in
        // `dispatchGroupSave` — we never await it from here so this
        // remains a pure local-side function.
        appState.dispatchGroupSave(withCreator)

        // Initial User publish — try once immediately, fall back to
        // the persisted retry queue on failure. This guarantees the
        // owner's member record durably reaches CloudKit (so cloud-
        // only observers see them) even if the create fired in
        // airplane mode and the app got killed before the network
        // came back.
        appState.dispatchMemberPublish(me, in: withCreator)

        // Seed the event log via the standard `emit` path so each
        // event flows through `pendingEmits` retry + BLE gossip. The
        // 1ms gap between the two events keeps them in the right
        // order during reducer replay.
        appState.emit(
            .groupCreated(
                name: withCreator.name,
                inviteCode: withCreator.inviteCode,
                category: withCreator.category,
                expiresAt: withCreator.expiresAt
            ),
            in: withCreator.id
        )
        let joinedID = Event.memberJoinedEventID(
            groupID: withCreator.id,
            memberID: me.id
        )
        let joinedEvent = Event(
            id: joinedID,
            groupID: withCreator.id,
            authorID: me.id,
            createdAt: .now,
            payload: .memberJoined(
                memberID: me.id,
                displayName: me.displayName,
                avatarData: me.avatarData,
                banHash: me.banHash
            )
        )
        appState.emit(joinedEvent)

        // Permission prompt + T-30 expiry reminder. Detached so the
        // system prompt doesn't block navigation.
        Task { [appState, withCreator] in
            await appState.registerNotifications(for: withCreator)
        }
    }
}

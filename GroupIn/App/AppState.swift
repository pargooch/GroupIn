//
//  AppState.swift
//  GroupIn
//
//  Global app state shared across views via the SwiftUI environment.
//
//  Identity model — anonymous-per-group:
//    • `localProfile` (name + avatar) lives only on this device.
//    • Each create/join mints a fresh UUID for the local membership;
//      `membershipByGroupID` records that mapping.
//    • Editing the profile propagates name/avatar into all existing
//      memberships, but UUIDs stay stable per group.
//

import Foundation
import CoreLocation
import Observation

enum AppRoute: Hashable {
    case createGroup
    case joinGroup
    case groupDashboard(groupID: UUID)
    case profileEditor
}

@MainActor
@Observable
final class AppState {
    var localProfile: LocalProfile {
        didSet {
            persistLocalProfile()
            propagateProfileToMemberships()
        }
    }
    /// Active membership. Reconstructed at launch from `currentGroup +
    /// membershipByGroupID`; not persisted directly since `currentGroup`
    /// is already the canonical source of member data.
    var currentUser: User
    var currentGroup: GroupSession? {
        didSet { persistCurrentGroup() }
    }
    var myGroups: [GroupSession] = [] {
        didSet { persistMyGroups() }
    }
    private(set) var membershipByGroupID: [UUID: UUID] = [:] {
        didSet { persistMembershipMap() }
    }
    var path: [AppRoute] = []

    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    let groupService: CloudKitServicing
    let locationService: LocationServicing
    let notificationService: NotificationServicing

    private let defaults: UserDefaults
    private var locationTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var expiryMonitorTask: Task<Void, Never>?
    private var notificationTapTask: Task<Void, Never>?
    private var groupRefreshTask: Task<Void, Never>?
    private var lastLocationPublishAt: Date?
    private static let publishInterval: TimeInterval = 10

    private static let localProfileKey = "GroupIn.AppState.localProfile"
    private static let currentGroupKey = "GroupIn.AppState.currentGroup"
    private static let myGroupsKey = "GroupIn.AppState.myGroups"
    private static let membershipMapKey = "GroupIn.AppState.membershipMap"

    var isInGroup: Bool { currentGroup != nil }

    init(localProfile: LocalProfile? = nil,
         groupService: CloudKitServicing? = nil,
         locationService: LocationServicing? = nil,
         notificationService: NotificationServicing? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let resolvedProfile = localProfile ?? Self.loadLocalProfile(defaults: defaults)
        self.localProfile = resolvedProfile

        // Placeholder — overwritten when a group is opened or restored.
        self.currentUser = User(displayName: resolvedProfile.displayName,
                                avatarData: resolvedProfile.avatarData)

        self.groupService = groupService ?? LocalGroupService(defaults: defaults)
        let resolvedLocation = locationService ?? LocationService()
        self.locationService = resolvedLocation
        self.locationAuthorizationStatus = resolvedLocation.authorizationStatus

        self.notificationService = notificationService ?? NotificationService()

        self.membershipByGroupID = Self.loadMembershipMap(defaults: defaults)

        if let data = defaults.data(forKey: Self.myGroupsKey),
           let decoded = try? JSONDecoder().decode([GroupSession].self, from: data) {
            self.myGroups = decoded
        }

        if let data = defaults.data(forKey: Self.currentGroupKey),
           let restored = try? JSONDecoder().decode(GroupSession.self, from: data) {
            self.currentGroup = restored
            self.path = [.groupDashboard(groupID: restored.id)]
            // Refresh currentUser to the right per-group membership.
            if let myID = membershipByGroupID[restored.id],
               let me = restored.members.first(where: { $0.id == myID }) {
                self.currentUser = me
            }
        }

        Self.persistLocalProfile(resolvedProfile, defaults: defaults)

        startExpiryMonitor()
        startNotificationTapMonitor()
    }

    // MARK: - Membership construction

    /// Builds a fresh per-group `User` from the current local profile.
    /// Caller is responsible for registering the membership ID via
    /// `registerMembership(groupID:memberID:)` once the group exists.
    func makeMembership() -> User {
        User(id: UUID(),
             displayName: localProfile.displayName,
             avatarData: localProfile.avatarData)
    }

    func registerMembership(groupID: UUID, memberID: UUID) {
        membershipByGroupID[groupID] = memberID
    }

    private func propagateProfileToMemberships() {
        // Update myGroups in place.
        var updated = myGroups
        var didChange = false
        for groupIdx in updated.indices {
            guard let myID = membershipByGroupID[updated[groupIdx].id],
                  let memberIdx = updated[groupIdx].members.firstIndex(where: { $0.id == myID })
            else { continue }
            updated[groupIdx].members[memberIdx].displayName = localProfile.displayName
            updated[groupIdx].members[memberIdx].avatarData = localProfile.avatarData
            didChange = true
        }
        if didChange { myGroups = updated }

        // Mirror into the active group + currentUser.
        if let group = currentGroup,
           let myID = membershipByGroupID[group.id],
           let memberIdx = group.members.firstIndex(where: { $0.id == myID }) {
            var refreshed = group
            refreshed.members[memberIdx].displayName = localProfile.displayName
            refreshed.members[memberIdx].avatarData = localProfile.avatarData
            currentGroup = refreshed
            currentUser = refreshed.members[memberIdx]
        } else {
            // No active membership — keep currentUser's name/avatar in sync as a placeholder.
            currentUser.displayName = localProfile.displayName
            currentUser.avatarData = localProfile.avatarData
        }
    }

    // MARK: - Group management

    func addOrUpdate(group: GroupSession) {
        if let idx = myGroups.firstIndex(where: { $0.id == group.id }) {
            myGroups[idx] = group
        } else {
            myGroups.append(group)
        }
    }

    func remove(group: GroupSession) {
        myGroups.removeAll { $0.id == group.id }
        membershipByGroupID.removeValue(forKey: group.id)
        if currentGroup?.id == group.id {
            currentGroup = nil
        }
        Task { [notificationService, groupID = group.id] in
            await notificationService.cancelAll(for: groupID)
        }
    }

    func open(group: GroupSession) {
        addOrUpdate(group: group)
        if let myID = membershipByGroupID[group.id],
           let me = group.members.first(where: { $0.id == myID }) {
            currentUser = me
        }
        currentGroup = group
        let route = AppRoute.groupDashboard(groupID: group.id)
        if path.last != route {
            path.append(route)
        }
    }

    func leaveGroup() {
        currentGroup = nil
        path.removeAll()
    }

    // MARK: - Location lifecycle

    func startLocationTracking() {
        locationService.requestAuthorization()
        locationService.startUpdating()

        if locationTask == nil {
            locationTask = Task { [weak self] in
                guard let self else { return }
                for await coordinate in self.locationService.locationUpdates {
                    var me = self.currentUser
                    me.coordinate = coordinate
                    me.lastSeen = .now
                    self.currentUser = me

                    if var group = self.currentGroup,
                       let idx = group.members.firstIndex(where: { $0.id == me.id }) {
                        group.members[idx] = me
                        self.currentGroup = group
                        self.addOrUpdate(group: group)

                        self.publishLocationIfNeeded(member: me, in: group)
                    }
                }
            }
        }

        if authTask == nil {
            authTask = Task { [weak self] in
                guard let self else { return }
                for await status in self.locationService.authorizationUpdates {
                    self.locationAuthorizationStatus = status
                }
            }
        }
    }

    func stopLocationTracking() {
        locationService.stopUpdating()
    }

    /// Throttled CloudKit publish: at most once every `publishInterval`
    /// seconds. Uses fire-and-forget so location updates never block.
    private func publishLocationIfNeeded(member: User, in group: GroupSession) {
        let now = Date()
        if let last = lastLocationPublishAt,
           now.timeIntervalSince(last) < Self.publishInterval {
            return
        }
        lastLocationPublishAt = now
        Task { [groupService, member, group] in
            try? await groupService.publish(user: member, in: group)
        }
    }

    // MARK: - Group refresh
    //
    // While a group is open, poll its server-side state every 10s so new
    // members and updated coordinates appear without manual refresh. This
    // is a stand-in for CKQuerySubscription (next CloudKit step).

    func startGroupRefresh() {
        guard groupRefreshTask == nil else { return }
        groupRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshCurrentGroup()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopGroupRefresh() {
        groupRefreshTask?.cancel()
        groupRefreshTask = nil
    }

    private func refreshCurrentGroup() async {
        guard let active = currentGroup else { return }
        do {
            guard var updated = try await groupService.fetchGroup(groupID: active.id) else {
                // Server-side gone — let the expiry monitor handle removal.
                return
            }
            // Preserve our local "self" entry so a stale server fetch doesn't
            // clobber a fresh local fix that's still in-flight to CloudKit.
            if let myID = membershipByGroupID[updated.id],
               let myIdx = updated.members.firstIndex(where: { $0.id == myID }) {
                updated.members[myIdx] = currentUser
            }
            currentGroup = updated
            addOrUpdate(group: updated)
        } catch {
            // Silent fail — keep last known good state, retry next tick.
        }
    }

    // MARK: - Notifications

    /// Schedule the owner-only T-30 expiry reminder for a group. Requests
    /// permission on first use; silently no-ops if denied or non-owner.
    func registerNotifications(for group: GroupSession) async {
        guard group.ownerID == currentUser.id else { return }
        let granted = await notificationService.requestAuthorization()
        guard granted else { return }
        await notificationService.scheduleExpiryReminder(for: group)
    }

    private func startNotificationTapMonitor() {
        guard notificationTapTask == nil else { return }
        notificationTapTask = Task { [weak self] in
            guard let self else { return }
            for await tap in self.notificationService.notificationTaps {
                self.handleNotificationTap(tap)
            }
        }
    }

    private func handleNotificationTap(_ tap: NotificationTap) {
        if let group = myGroups.first(where: { $0.id == tap.groupID }) {
            open(group: group)
        }
    }

    // MARK: - Group expiry / extension

    /// Owner-only. Proposes a new expiry; members must accept by the
    /// original expiry to remain.
    func proposeCurrentExtension(newExpiresAt: Date) async throws {
        guard let group = currentGroup else { return }
        let updated = try await groupService.proposeExtension(
            groupID: group.id,
            newExpiresAt: newExpiresAt
        )
        addOrUpdate(group: updated)
        currentGroup = updated
    }

    /// Member accepts the active extension proposal on `currentGroup`.
    func acceptCurrentExtension() async throws {
        guard let group = currentGroup else { return }
        let updated = try await groupService.acceptExtension(
            groupID: group.id,
            memberID: currentUser.id
        )
        addOrUpdate(group: updated)
        currentGroup = updated
    }

    /// Returns whether the local user is the owner of the currently active group.
    var isCurrentGroupOwner: Bool {
        guard let group = currentGroup else { return false }
        return group.ownerID == currentUser.id
    }

    // MARK: - Expiry monitor
    //
    // One long-lived Task wakes every 30s, pulls any expired groups
    // through the service, and updates local state. Cheap (a single
    // comparison per group per minute) and correct enough for v1.

    private func startExpiryMonitor() {
        guard expiryMonitorTask == nil else { return }
        expiryMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.processExpiryTick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func processExpiryTick() async {
        let now = Date()
        let expired = myGroups.filter { $0.expiresAt <= now }
        for group in expired {
            do {
                let resolved = try await groupService.resolveExpiry(groupID: group.id)
                if let resolved {
                    addOrUpdate(group: resolved)
                    if currentGroup?.id == group.id {
                        currentGroup = resolved
                        if let myID = membershipByGroupID[group.id],
                           let me = resolved.members.first(where: { $0.id == myID }) {
                            currentUser = me
                        } else {
                            // I didn't accept — pop back to home.
                            leaveGroup()
                        }
                    }
                    // Reschedule reminder for the new expiry.
                    await registerNotifications(for: resolved)
                } else {
                    remove(group: group)
                }
            } catch {
                // Retry next tick.
            }
        }
    }

    // MARK: - Persistence

    private func persistCurrentGroup() {
        if let group = currentGroup,
           let data = try? JSONEncoder().encode(group) {
            defaults.set(data, forKey: Self.currentGroupKey)
        } else {
            defaults.removeObject(forKey: Self.currentGroupKey)
        }
    }

    private func persistMyGroups() {
        if let data = try? JSONEncoder().encode(myGroups) {
            defaults.set(data, forKey: Self.myGroupsKey)
        }
    }

    private func persistLocalProfile() {
        Self.persistLocalProfile(localProfile, defaults: defaults)
    }

    private func persistMembershipMap() {
        let stringMap = membershipByGroupID.reduce(into: [String: String]()) { acc, pair in
            acc[pair.key.uuidString] = pair.value.uuidString
        }
        if let data = try? JSONEncoder().encode(stringMap) {
            defaults.set(data, forKey: Self.membershipMapKey)
        }
    }

    private static func persistLocalProfile(_ profile: LocalProfile, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: localProfileKey)
        }
    }

    private static func loadLocalProfile(defaults: UserDefaults) -> LocalProfile {
        if let data = defaults.data(forKey: localProfileKey),
           let decoded = try? JSONDecoder().decode(LocalProfile.self, from: data) {
            return decoded
        }
        return .default
    }

    private static func loadMembershipMap(defaults: UserDefaults) -> [UUID: UUID] {
        guard let data = defaults.data(forKey: membershipMapKey),
              let stringMap = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return stringMap.reduce(into: [UUID: UUID]()) { acc, pair in
            if let key = UUID(uuidString: pair.key),
               let value = UUID(uuidString: pair.value) {
                acc[key] = value
            }
        }
    }
}

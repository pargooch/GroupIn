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

enum TransportSource {
    case cloud
    case ble
}

struct PeerSourceTracking: Equatable {
    var lastCloudUpdate: Date?
    var lastBLEUpdate: Date?

    /// The most recent transport that delivered an update inside the
    /// freshness window. Nil if neither is fresh.
    func dominant(now: Date = .now,
                  freshnessWindow: TimeInterval) -> TransportSource? {
        let cloudFresh = lastCloudUpdate.map {
            now.timeIntervalSince($0) < freshnessWindow
        } ?? false
        let bleFresh = lastBLEUpdate.map {
            now.timeIntervalSince($0) < freshnessWindow
        } ?? false
        if bleFresh && cloudFresh,
           let bleAt = lastBLEUpdate, let cloudAt = lastCloudUpdate {
            return bleAt > cloudAt ? .ble : .cloud
        }
        if bleFresh { return .ble }
        if cloudFresh { return .cloud }
        return nil
    }
}

enum ConnectionMode: Equatable {
    case onlineWithPeers   // internet + at least one nearby BLE peer
    case online            // internet only, no BLE peers
    case peersOnly         // no internet, BLE peers present
    case offline           // no internet, no peers — last known only
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
        didSet {
            persistCurrentGroup()
            // Find My / Live Location-style: location flows for the
            // duration of group membership, not just while the dashboard
            // is on screen. Lock the phone, navigate Home, drop the app
            // into background — sharing keeps going until you Leave.
            // iBeacon region monitoring follows the same lifecycle so we
            // can wake on peer proximity even when the app is closed.
            switch (oldValue, currentGroup) {
            case (nil, .some):
                startLocationTracking()
                startBeaconMonitoring()
            case (.some, nil):
                stopLocationTracking()
                stopBeaconMonitoring()
            default:
                break
            }
        }
    }
    var myGroups: [GroupSession] = [] {
        didSet { persistMyGroups() }
    }
    private(set) var membershipByGroupID: [UUID: UUID] = [:] {
        didSet { persistMembershipMap() }
    }
    var path: [AppRoute] = []

    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True when the device has internet (any path satisfied).
    /// Driven by NWPathMonitor.
    var isOnline: Bool = true

    /// Per-peer last-seen timestamps per transport. Drives the
    /// connection-mode badge and the per-row transport icon.
    private(set) var peerSources: [UUID: PeerSourceTracking] = [:]
    private static let transportFreshnessWindow: TimeInterval = 60

    let groupService: CloudKitServicing
    let locationService: LocationServicing
    let notificationService: NotificationServicing
    let blePresenceService: BLEPresenceServicing
    let beaconMonitor: BeaconMonitorService

    private let defaults: UserDefaults
    private var networkMonitor: NetworkMonitor?
    private var locationTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var expiryMonitorTask: Task<Void, Never>?
    private var notificationTapTask: Task<Void, Never>?
    private var groupRefreshTask: Task<Void, Never>?
    private var lastLocationPublishAt: Date?
    private static let publishInterval: TimeInterval = 10
    private var bleConsumerTask: Task<Void, Never>?
    private var headingTask: Task<Void, Never>?
    private var headingBuffer: [Double] = []
    private static let headingSmoothingWindow = 5

    private static let localProfileKey = "GroupIn.AppState.localProfile"
    private static let currentGroupKey = "GroupIn.AppState.currentGroup"
    private static let myGroupsKey = "GroupIn.AppState.myGroups"
    private static let membershipMapKey = "GroupIn.AppState.membershipMap"

    var isInGroup: Bool { currentGroup != nil }

    init(localProfile: LocalProfile? = nil,
         groupService: CloudKitServicing? = nil,
         locationService: LocationServicing? = nil,
         notificationService: NotificationServicing? = nil,
         blePresenceService: BLEPresenceServicing? = nil,
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
        self.blePresenceService = blePresenceService ?? BLEAdvertisementService()
        self.beaconMonitor = BeaconMonitorService()

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
        startNetworkMonitor()
        configureBeaconMonitor()

        // didSet doesn't fire during init, so if we restored a group from
        // persistence, kick off location explicitly. The user comes back
        // to a phone that's been locked all night and sharing is already
        // alive when they unlock — same as Find My.
        if currentGroup != nil {
            startLocationTracking()
            startBeaconMonitoring()
        }
    }

    /// Wires the iBeacon region monitor's entry callback into the
    /// notification service. This is the path that fires when iOS wakes
    /// the app from a force-quit state because a group peer's iBeacon
    /// came into range.
    private func configureBeaconMonitor() {
        beaconMonitor.onEnter = { [weak self] in
            guard let self else { return }
            // Use whichever group context we have. If currentGroup is
            // nil (race during launch) prefer the most recently used.
            guard let group = self.currentGroup ?? self.myGroups.first else { return }
            Task { [notificationService = self.notificationService, groupID = group.id] in
                await notificationService.firePeerNearbyNotification(for: groupID)
            }
        }
    }

    private func startBeaconMonitoring() {
        beaconMonitor.start()
    }

    private func stopBeaconMonitoring() {
        beaconMonitor.stop()
    }

    private func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NetworkMonitor()
        monitor.onChange = { [weak self] online in
            self?.isOnline = online
        }
        // Seed from current state so we don't have to wait for the first
        // path change before the UI reflects reality.
        self.isOnline = monitor.isOnline
        self.networkMonitor = monitor
    }

    // MARK: - Transport tracking

    func recordTransport(_ source: TransportSource, for memberID: UUID) {
        var tracking = peerSources[memberID] ?? PeerSourceTracking()
        switch source {
        case .cloud: tracking.lastCloudUpdate = .now
        case .ble:   tracking.lastBLEUpdate = .now
        }
        peerSources[memberID] = tracking
    }

    func transportSource(for memberID: UUID) -> TransportSource? {
        peerSources[memberID]?.dominant(
            freshnessWindow: Self.transportFreshnessWindow
        )
    }

    var hasNearbyPeer: Bool {
        let now = Date()
        return peerSources.values.contains { source in
            guard let bleAt = source.lastBLEUpdate else { return false }
            return now.timeIntervalSince(bleAt) < Self.transportFreshnessWindow
        }
    }

    var connectionMode: ConnectionMode {
        switch (isOnline, hasNearbyPeer) {
        case (true, true):   return .onlineWithPeers
        case (true, false):  return .online
        case (false, true):  return .peersOnly
        case (false, false): return .offline
        }
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
                        self.broadcastBLEPresence()
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

        if headingTask == nil {
            headingTask = Task { [weak self] in
                guard let self else { return }
                for await heading in self.locationService.headingUpdates {
                    let smoothed = self.smoothHeading(heading)

                    var me = self.currentUser
                    me.heading = smoothed
                    self.currentUser = me

                    // Mirror into the active group's local member entry so
                    // the local pin's cone updates immediately. Heading is
                    // also picked up by the next BLE/CloudKit broadcast
                    // (which fires on location updates, not heading).
                    if var group = self.currentGroup,
                       let idx = group.members.firstIndex(where: { $0.id == me.id }) {
                        group.members[idx].heading = smoothed
                        self.currentGroup = group
                    }
                }
            }
        }
    }

    /// Circular moving average over the last few heading samples. Plain
    /// averaging is wrong for compass bearings — averaging 350° and 10°
    /// would yield 180° instead of the correct 0°. Going through the
    /// unit circle with sin/cos and atan2 handles the wrap.
    private func smoothHeading(_ raw: Double) -> Double {
        headingBuffer.append(raw)
        if headingBuffer.count > Self.headingSmoothingWindow {
            headingBuffer.removeFirst()
        }
        let radians = headingBuffer.map { $0 * .pi / 180 }
        let n = Double(headingBuffer.count)
        let sumX = radians.map(cos).reduce(0, +) / n
        let sumY = radians.map(sin).reduce(0, +) / n
        let meanRad = atan2(sumY, sumX)
        let meanDeg = meanRad * 180 / .pi
        return (meanDeg + 360).truncatingRemainder(dividingBy: 360)
    }

    func stopLocationTracking() {
        locationService.stopUpdating()
    }

    // MARK: - BLE peer presence

    /// Start broadcasting + scanning for nearby group members over BLE.
    /// Pairs with `stopBLEPresence()` on dashboard disappear.
    func startBLEPresence() {
        guard let group = currentGroup else { return }
        let presence = makeLocalPresence(for: group)
        blePresenceService.start(
            groupHash: presence.groupHash,
            localPresence: presence
        )

        if bleConsumerTask == nil {
            bleConsumerTask = Task { [weak self] in
                guard let self else { return }
                for await peer in self.blePresenceService.peerUpdates {
                    self.mergeBLEPeer(peer)
                }
            }
        }
    }

    func stopBLEPresence() {
        blePresenceService.stop()
    }

    private func makeLocalPresence(for group: GroupSession) -> PeerPresence {
        PeerPresence(
            groupHash: PeerPresence.groupHash(forInviteCode: group.inviteCode),
            memberID: currentUser.id,
            latitude: currentUser.coordinate?.latitude,
            longitude: currentUser.coordinate?.longitude,
            heading: currentUser.heading,
            lastSeen: currentUser.lastSeen
        )
    }

    /// Re-broadcast the current presence over BLE. Called after every
    /// fix while the dashboard is open.
    private func broadcastBLEPresence() {
        guard let group = currentGroup else { return }
        blePresenceService.update(localPresence: makeLocalPresence(for: group))
    }

    /// Merge a freshly-read peer presence into `currentGroup.members`.
    /// Only applies when the peer's lastSeen is newer than our cached
    /// version — same "newest wins" rule we use for CloudKit refresh.
    private func mergeBLEPeer(_ peer: PeerPresence) {
        guard var group = currentGroup else { return }
        guard let idx = group.members.firstIndex(where: { $0.id == peer.memberID }) else {
            // Unknown member — they may not have synced via CloudKit yet.
            // Skip; the next CloudKit refresh will surface them and the
            // following BLE read will then merge.
            return
        }
        // Always record BLE contact even if the data isn't strictly fresher;
        // the connection-mode pill cares about "we're hearing them on
        // Bluetooth," not just "their position changed."
        recordTransport(.ble, for: peer.memberID)
        guard peer.lastSeen > group.members[idx].lastSeen else { return }
        group.members[idx].lastSeen = peer.lastSeen
        if let lat = peer.latitude, let lon = peer.longitude {
            group.members[idx].coordinate = Coordinate(latitude: lat, longitude: lon)
        }
        group.members[idx].heading = peer.heading
        currentGroup = group
        addOrUpdate(group: group)
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
            // Newest-wins merge per member. Without this, an offline peer's
            // BLE-sourced fresh location gets clobbered every 10 s by the
            // stale copy CloudKit still has from before they went offline.
            for i in updated.members.indices {
                let cloudMember = updated.members[i]
                let localCopy = active.members.first(where: { $0.id == cloudMember.id })
                if let local = localCopy, local.lastSeen > cloudMember.lastSeen {
                    updated.members[i] = local
                } else if cloudMember.lastSeen > (localCopy?.lastSeen ?? .distantPast) {
                    // Cloud has fresher data — note that this peer is
                    // currently reachable via the cloud transport.
                    recordTransport(.cloud, for: cloudMember.id)
                }
            }
            // Self entry: prefer the live `currentUser` if it's newer than
            // either cloud or the active cached copy.
            if let myID = membershipByGroupID[updated.id],
               let myIdx = updated.members.firstIndex(where: { $0.id == myID }),
               currentUser.lastSeen >= updated.members[myIdx].lastSeen {
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

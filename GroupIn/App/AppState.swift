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
import CryptoKit
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
    /// The group whose dashboard the user is currently viewing. Used
    /// for UI focus only — **tracking lifecycle is driven by `myGroups`,
    /// not this property.** Closing the dashboard via Done leaves this
    /// set (so reopening is instant); only an explicit leave/delete
    /// or a banned/deleted notice clears it.
    var currentGroup: GroupSession? {
        didSet { persistCurrentGroup() }
    }

    /// Authoritative list of groups the user is a member of. Tracking
    /// (location, beacons, heartbeat) starts when this becomes
    /// non-empty and stops when it goes back to empty. Per-group
    /// CloudKit subscriptions are added/removed based on the diff
    /// between the previous and new list, so receiving silent pushes
    /// for a group follows membership instead of dashboard focus.
    var myGroups: [GroupSession] = [] {
        didSet {
            persistMyGroups()
            reconcileTrackingLifecycle(previous: oldValue, current: myGroups)
        }
    }
    private(set) var membershipByGroupID: [UUID: UUID] = [:] {
        didSet { persistMembershipMap() }
    }

    /// Per-group event cursor — the `(createdAt, id)` of the newest
    /// event we've applied locally. Sync resumes from here on every
    /// CloudKit push or pull-to-refresh. Persisted to UserDefaults so
    /// cold starts don't replay the whole log from scratch.
    private var eventCursors: [UUID: EventCursor] = [:] {
        didSet { persistEventCursors() }
    }

    /// Per-group "oldest local event" cursor — used for paginated
    /// scroll-to-top history loading. The UI calls
    /// `loadOlderEvents(for:)` and we fetch `Self.timelinePageSize`
    /// events older than this, prepend to the local store, and update
    /// this cursor to the oldest of the new batch. Nil means we
    /// haven't loaded any events yet for this group.
    private var oldestEventCursors: [UUID: EventCursor] = [:] {
        didSet { persistOldestEventCursors() }
    }

    /// Set of groups where we've fetched an "older" batch that came
    /// back with fewer than the page size — meaning we've reached the
    /// start of the group's recorded history. The timeline UI uses
    /// this to show a "Start of group" marker and stop firing more
    /// load-older requests.
    private(set) var groupsAtStartOfHistory: Set<UUID> = []

    /// Locally-persisted event log per group. Populated by every event
    /// ingestion path: local emits, CloudKit forward sync, CloudKit
    /// older-batch fetches, BLE gossip. The timeline UI reads from
    /// here exclusively — never directly from the CloudKit service —
    /// so it works offline and renders instantly from cache.
    private(set) var eventsByGroup: [UUID: [Event]] = [:] {
        didSet { persistEventsByGroup() }
    }

    /// Page size for paginated `loadOlderEvents(for:)`. Returning
    /// fewer than this in a batch marks the start of the group's
    /// history.
    private static let timelinePageSize = 30

    /// Delivery status for events the local user authored — drives
    /// the WhatsApp-style ⏰/✓/✓✓ dot on outgoing chat bubbles.
    /// Persisted so the UI doesn't lose state across app launches.
    /// Only mutated through `advanceDelivery(_:to:)` which enforces
    /// the never-go-backwards rule.
    private var eventDeliveryByID: [UUID: EventDeliveryStatus] = [:] {
        didSet { persistEventDelivery() }
    }

    /// Persisted retry queue for events whose CloudKit append failed.
    /// Drained by `retryEmitTask` on an exponential-backoff schedule;
    /// also retried opportunistically on every successful sync (since
    /// "sync succeeded" implies CloudKit is reachable). Restored on
    /// app launch so an unflushed event survives a force-quit.
    private var pendingEmits: [PendingEmit] = [] {
        didSet { persistPendingEmits() }
    }
    /// Persisted retry queue for `saveGroup` calls that failed —
    /// covers the offline-first group creation path. Same drain
    /// cadence and backoff schedule as `pendingEmits`. The user can
    /// create a group with no network, navigate to its dashboard,
    /// chat with anyone in BLE range; the CloudKit upload happens
    /// in the background once a connection returns.
    private var pendingGroupSaves: [PendingGroupSave] = [] {
        didSet { persistPendingGroupSaves() }
    }
    /// Persisted retry queue for member-record publishes that failed
    /// — covers the create-group and join-group paths where we mint
    /// a `User` locally and need to durably ship it to CloudKit so
    /// peers who only see us via the cloud know we exist. Without
    /// this, a publish failure was silently dropped (the old
    /// `try? await groupService.publish(...)` pattern) and the
    /// member became permanently invisible to cloud-only observers.
    private var pendingMemberPublishes: [PendingMemberPublish] = [] {
        didSet { persistPendingMemberPublishes() }
    }
    private var retryEmitTask: Task<Void, Never>?
    /// Tick interval for the retry task. We wake on this cadence and
    /// drain any pending emits / group saves whose `nextRetryAt` has
    /// passed.
    private static let retryTickInterval: TimeInterval = 5
    var path: [AppRoute] = []

    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Latest known iCloud account state from the active backend.
    /// `.couldNotDetermine` is the conservative starting value; we
    /// refresh at launch and on every CKAccountChanged broadcast.
    var iCloudAccountStatus: ICloudAccountStatus = .couldNotDetermine

    /// Cached anonymous identifier for the local user — `recordName`
    /// of `CKContainer.userRecordID()` for the CloudKit backend, or a
    /// per-install UUID for the local stub. Populated asynchronously
    /// at launch; nil until the first fetch succeeds. Used purely as
    /// the salt input for `BanHash.compute(...)`.
    private(set) var localCloudUserID: String?

    /// Set when the active group's refresh notices our `banHash` in
    /// its `bannedMembers`. The dashboard's modifier surfaces an alert
    /// + dismisses the screen so the user lands back on Home with a
    /// clear explanation. Cleared after the alert is acknowledged.
    var bannedFromGroupName: String?

    /// Set when a refresh discovers the active group was hard-deleted
    /// server-side (owner pressed Delete, or it expired and was
    /// cleaned up). The dashboard's modifier surfaces a one-time
    /// "this group was deleted" alert and pops back to Home. Cleared
    /// after the alert is dismissed.
    var groupDeletedNotice: String?

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
    let motionService: MotionActivityServicing
    let uwbSessionService: UWBSessionServicing
    let deadReckoningService: DeadReckoningServicing
    /// Router that picks the best seeking channel (UWB → Wi-Fi Aware
    /// → BLE) per peer based on shared capability bits, and forwards
    /// ranging samples upward under one stable stream.
    let seekingRouter: SeekingRouter
    /// Payload-tier transport — carries chat + event-log gossip + (Phase 4)
    /// capability and anchor messages. BLE remains the signal tier
    /// (presence heartbeat, join handshake, wake-on-proximity); anything
    /// substantive flows through here on MPC or Wi-Fi Aware.
    let payloadTransport: PayloadTransport

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
    /// Consumer of the seeking router's unified ranging stream.
    /// Replaces the old per-channel `bleRSSITask` and
    /// `uwbReadingsTask` — every channel's samples now arrive here.
    private var seekingRouterTask: Task<Void, Never>?
    private var headingTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var headingBuffer: [Double] = []
    private static let headingSmoothingWindow = 5

    /// Compass gradient state. Public so view models can query bearings;
    /// AppState owns the writes.
    private(set) var compassEngine = CompassEngine()

    /// Most recent UWB reading per peer. The compass view reads this to
    /// override its GPS/RSSI bearing when a fresh reading is present.
    /// Populated by `handleRangingSample` whenever the seeking router
    /// forwards a UWB or Wi-Fi Aware sample with distance/direction.
    private(set) var uwbReadings: [UUID: UWBReading] = [:]

    /// Rolling buffer of chat messages applied for the active group,
    /// populated from the unified event log (`.chatMessage` events).
    /// Capped at 100 to avoid growth. Newest at the end, so chat list
    /// rendering reads naturally top-to-bottom = oldest-to-newest.
    private(set) var chatMessages: [ChatMessage] = []
    private static let chatBufferLimit = 100

    /// Live BLE diagnostics — surfaced in the chat sheet so the user
    /// can see whether anyone's actually subscribed to receive their
    /// messages. Populated from the BLE service's diagnostics stream.
    private(set) var bleDiagnostics: BLEDiagnostics = BLEDiagnostics(
        presenceSubscribers: 0,
        serviceAddFailed: false,
        bluetoothReady: true
    )
    private var bleDiagnosticsTask: Task<Void, Never>?

    /// Live payload-transport diagnostics — connected MPC / Wi-Fi
    /// Aware peers. Drives the "Sending to X nearby" indicator that
    /// used to read from `bleDiagnostics.chatSubscribers`.
    private(set) var transportDiagnostics: TransportDiagnostics =
        TransportDiagnostics.inactive
    private var transportDiagnosticsTask: Task<Void, Never>?

    /// Live seeking-router diagnostics — which channel is currently
    /// engaged (UWB / Wi-Fi Aware / BLE) and per-peer sample counts.
    /// Surfaces the `ch:` chip in the indoor compass strip.
    private(set) var seekingDiagnostics: SeekingDiagnostics = .empty
    private var seekingDiagnosticsTask: Task<Void, Never>?
    private var iCloudAccountChangeTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var bleJoinRequestTask: Task<Void, Never>?
    private var deadReckoningTask: Task<Void, Never>?
    private var compassStepTask: Task<Void, Never>?

    /// Payload-transport consumer task — decodes incoming `PayloadFrame`s
    /// and routes events into the same `handleGossipedEvent` pipeline
    /// that BLE used to feed.
    private var payloadIncomingTask: Task<Void, Never>?
    /// Group ID of the rendezvous currently active on the transport.
    /// `nil` when the transport isn't running. Used to decide whether
    /// a presence start needs to restart the transport too.
    private var activeTransportGroupID: UUID?

    /// Asymmetric activity role:
    ///
    /// - `.seeker`: app is foreground / actively in use. Runs the full
    ///   stack — BLE central + peripheral, payload transport, sensor
    ///   fusion, compass UI. Pays the battery cost.
    /// - `.sought`: app is backgrounded. BLE peripheral keeps advertising
    ///   so other people can find *me*; nothing else spins up
    ///   proactively. The payload transport sleeps and only comes alive
    ///   when a seeker wakes us via BLE state restoration.
    ///
    /// Driven by `applyScenePhase(_:)` from the root view.
    enum Role { case seeker, sought }
    private(set) var role: Role = .seeker

    /// Timestamp of the most recent fresh GPS fix. The DR consumer
    /// uses this to decide whether to apply DR estimates (only when
    /// the GPS has gone stale, ~30s+ since last fix).
    private var lastGPSFixAt: Date?

    /// True once we've received at least one GPS fix during this app
    /// session. Used by the B.2.2 hypothetical-source publishing
    /// path — if we *never* had GPS this session, our own position
    /// publishes as `.hypothetical` so other members render us
    /// distinctly.
    private var hasEverHadGPSThisSession: Bool = false

    /// GPS staleness threshold for switching to DR. Below this, fresh
    /// GPS wins; above it, DR fills in until the next fix arrives.
    private static let gpsStaleAfter: TimeInterval = 30

    /// Last-known event cursor for each in-range BLE peer. Populated
    /// from PeerPresence broadcasts as they arrive; dropped when a
    /// peer disconnects (no TTL — broadcasts only reach currently-
    /// subscribed centrals, so stale cursors give no benefit).
    /// Used to decide whether a new event needs to be broadcast at
    /// all: if every tracked peer is already at or ahead of an
    /// event's cursor, we skip the BLE write.
    private var peerCursors: [UUID: EventCursor] = [:]

    /// Per-peer transport capability advertised in PeerPresence. Used
    /// by `recomputeGroupTransport()` to pick the group-min transport
    /// — Wi-Fi Aware only if every member supports it.
    private var peerCapabilities: [UUID: TransportCapability] = [:]

    private static let heartbeatInterval: TimeInterval = 20
    /// Threshold under which the heartbeat skips work — if a real GPS
    /// fix updated `lastSeen` recently, no need to pile on extra writes.
    private static let heartbeatStaleAfter: TimeInterval = 15

    private static let localProfileKey = "GroupIn.AppState.localProfile"
    private static let currentGroupKey = "GroupIn.AppState.currentGroup"
    private static let myGroupsKey = "GroupIn.AppState.myGroups"
    private static let membershipMapKey = "GroupIn.AppState.membershipMap"
    private static let eventCursorsKey = "GroupIn.AppState.eventCursors"
    private static let oldestEventCursorsKey = "GroupIn.AppState.oldestEventCursors"
    private static let eventsByGroupKey = "GroupIn.AppState.eventsByGroup"
    private static let eventDeliveryKey = "GroupIn.AppState.eventDelivery"
    private static let pendingEmitsKey = "GroupIn.AppState.pendingEmits"
    private static let pendingGroupSavesKey = "GroupIn.AppState.pendingGroupSaves"
    private static let pendingMemberPublishesKey = "GroupIn.AppState.pendingMemberPublishes"

    var isInGroup: Bool { currentGroup != nil }

    init(localProfile: LocalProfile? = nil,
         groupService: CloudKitServicing? = nil,
         locationService: LocationServicing? = nil,
         notificationService: NotificationServicing? = nil,
         blePresenceService: BLEPresenceServicing? = nil,
         payloadTransport: PayloadTransport? = nil,
         motionService: MotionActivityServicing? = nil,
         uwbSessionService: UWBSessionServicing? = nil,
         deadReckoningService: DeadReckoningServicing? = nil,
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
        self.payloadTransport = payloadTransport
            ?? PayloadTransportRouter(
                multipeer: MultipeerService(),
                wifiAware: WiFiAwareService()
            )
        self.beaconMonitor = BeaconMonitorService()
        self.motionService = motionService ?? MotionActivityService()
        self.uwbSessionService = uwbSessionService ?? UWBSessionService()
        self.deadReckoningService = deadReckoningService
            ?? DeadReckoningService(defaults: defaults)

        // Seeking router wires the three channels together. UWB and
        // BLE adapt around their existing services; Wi-Fi Aware is a
        // stub until the framework lands. Capability-driven selection
        // picks the highest tier supported by both sides per peer.
        self.seekingRouter = SeekingRouter(
            uwb: UWBSeekingChannel(uwbService: self.uwbSessionService),
            wifiAware: WiFiAwareRangingChannel(),
            ble: BLERangingChannel(bleService: self.blePresenceService)
        )
        self.seekingRouter.setLocalCapability(Self.localTransportCapability())

        self.membershipByGroupID = Self.loadMembershipMap(defaults: defaults)
        self.eventCursors = Self.loadEventCursors(defaults: defaults)
        self.oldestEventCursors = Self.loadOldestEventCursors(defaults: defaults)
        self.eventsByGroup = Self.loadEventsByGroup(defaults: defaults)
        self.eventDeliveryByID = Self.loadEventDelivery(defaults: defaults)
        self.pendingEmits = Self.loadPendingEmits(defaults: defaults)
        self.pendingGroupSaves = Self.loadPendingGroupSaves(defaults: defaults)
        self.pendingMemberPublishes = Self.loadPendingMemberPublishes(defaults: defaults)

        if let data = defaults.data(forKey: Self.myGroupsKey),
           let decoded = try? JSONDecoder().decode([GroupSession].self, from: data) {
            self.myGroups = decoded
        }

        if let data = defaults.data(forKey: Self.currentGroupKey),
           let restored = try? JSONDecoder().decode(GroupSession.self, from: data) {
            self.currentGroup = restored
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
        startPushHandler()
        startICloudAccountMonitor()
        startBLEDiagnosticsMonitor()
        loadLocalCloudUserID()
        startEmitRetryLoop()
        startJoinRequestResponder()

        // didSet doesn't fire during init, so if we restored any
        // memberships from persistence we need to kick off the
        // tracking stack explicitly. The user unlocks a phone that's
        // been quiet all night and sharing is already alive — same as
        // Find My.
        if !myGroups.isEmpty {
            startLocationTracking()
            startBeaconMonitoring()
            startPresenceHeartbeat()
            startBLEPresence()
            // Re-confirm the CloudKit subscription for every group on
            // every launch — the CKDatabase persists subscriptions
            // server-side, so duplicates are no-ops. Cheap insurance
            // against a subscription getting dropped between launches.
            //
            // Using `self.groupService` explicitly because the init
            // parameter named `groupService` is the optional-arg form
            // and would shadow the property otherwise.
            for restoredGroup in myGroups {
                Task { [groupService = self.groupService, groupID = restoredGroup.id] in
                    try? await groupService.subscribeToPresenceUpdates(groupID: groupID)
                    try? await groupService.subscribeToEvents(groupID: groupID)
                }
                // Catch up on events that landed while the app was
                // closed. Cursor-driven, so this is cheap on launch
                // if not much changed.
                Task { [weak self, groupID = restoredGroup.id] in
                    await self?.syncEvents(for: groupID)
                }
            }
        }
    }

    /// Wires the iBeacon region monitor's entry callback into the
    /// notification service. This is the path that fires when iOS wakes
    /// the app from a force-quit state because a group peer's iBeacon
    /// came into range.
    private func configureBeaconMonitor() {
        beaconMonitor.onEnter = { [weak self] beacons in
            guard let self else { return }
            // Use whichever group context we have. If currentGroup is
            // nil (race during launch) prefer the most recently used.
            guard let group = self.currentGroup ?? self.myGroups.first else { return }
            let expectedMajor = BLEAdvertisementService.collapseGroupHash(
                PeerPresence.groupHash(forInviteCode: group.inviteCode)
            )
            // Find the strongest in-range beacon whose major matches the
            // group and whose minor matches a known member. Multiple peers
            // can be in range — closest RSSI wins so the notification
            // names whoever's actually arrived.
            let candidates = beacons.filter { beacon in
                beacon.major.uint16Value == expectedMajor
                    && beacon.proximity != .unknown
            }
            let nearest = candidates.min(by: { lhs, rhs in
                // RSSI is negative; closer is higher. accuracy is metres
                // (lower = closer), more stable than raw RSSI.
                lhs.accuracy < rhs.accuracy && lhs.accuracy > 0
            })
            let peerName: String? = nearest.flatMap { beacon in
                let minor = UInt16(truncatingIfNeeded: beacon.minor.intValue)
                return group.members
                    .first(where: { $0.id != self.currentUser.id
                                    && $0.id.truncated16 == minor })?
                    .displayName
            }
            Task { [notificationService = self.notificationService,
                    groupID = group.id, peerName] in
                await notificationService.firePeerNearbyNotification(
                    for: groupID, peerName: peerName
                )
            }
        }
    }

    private func startBeaconMonitoring() {
        beaconMonitor.start()
    }

    private func stopBeaconMonitoring() {
        beaconMonitor.stop()
    }

    // MARK: - Tracking lifecycle reconciliation
    //
    // The user's membership in groups (`myGroups`) is what controls
    // whether the location/beacon/heartbeat stack is alive. Foreground
    // focus on a particular group (`currentGroup`) is purely a UI
    // concern. Splitting these means:
    //
    //   • Tapping "Done" on the dashboard doesn't stop tracking — the
    //     user is still a member, still publishing presence.
    //   • Tracking only winds down when the user is in zero groups
    //     (last membership left, or all expired). At that point the
    //     blue background-location indicator disappears, which is the
    //     correct UX signal.
    //   • CloudKit subscriptions follow membership too, so silent
    //     pushes for moderation/ban/expiry events still arrive while
    //     the dashboard is closed.

    private func reconcileTrackingLifecycle(previous: [GroupSession],
                                            current: [GroupSession]) {
        let previousIDs = Set(previous.map(\.id))
        let currentIDs = Set(current.map(\.id))

        let wasEmpty = previous.isEmpty
        let isEmpty = current.isEmpty

        // Whole-stack transitions: only fire when crossing the
        // "any group" / "no groups" boundary, not on every membership
        // tweak (members joining/leaving an existing group shouldn't
        // bounce our local sensors).
        if wasEmpty, !isEmpty {
            startLocationTracking()
            startBeaconMonitoring()
            startPresenceHeartbeat()
            startBLEPresence()
        } else if !wasEmpty, isEmpty {
            stopLocationTracking()
            stopBeaconMonitoring()
            stopPresenceHeartbeat()
            stopBLEPresence()
        }

        // Per-group subscription deltas — independent of the whole-
        // stack transition. Subscribe for groups that just appeared,
        // unsubscribe for groups that just left. Idempotent on the
        // backend side: a duplicate subscribe is a no-op, a missing
        // unsubscribe also a no-op.
        let added = currentIDs.subtracting(previousIDs)
        let removed = previousIDs.subtracting(currentIDs)
        for groupID in added {
            Task { [groupService = self.groupService, groupID] in
                try? await groupService.subscribeToPresenceUpdates(groupID: groupID)
                try? await groupService.subscribeToEvents(groupID: groupID)
            }
            // Catch up on any events that landed while we weren't
            // subscribed — between the previous unsubscribe and this
            // subscribe — by triggering an immediate event sync.
            Task { [weak self, groupID] in
                await self?.syncEvents(for: groupID)
            }
        }
        for groupID in removed {
            Task { [groupService = self.groupService, groupID] in
                try? await groupService.unsubscribeFromPresenceUpdates(groupID: groupID)
                try? await groupService.unsubscribeFromEvents(groupID: groupID)
            }
            // Drop the cursor too — if we ever rejoin this group, we
            // want a fresh sync rather than picking up from where we
            // left off (which could be wildly out of date).
            eventCursors.removeValue(forKey: groupID)
        }
    }

    // MARK: - Presence heartbeat
    //
    // Without this, peers see us "go offline" after ~30 s of being still.
    // The reason: the green/orange/red status badge each peer renders for
    // us is driven by our `lastSeen`, which only advances when
    // CLLocationManager fires a fresh fix. Stationary or backgrounded
    // devices stop producing fixes, so `lastSeen` ages even though we're
    // very much still in the group. This task republishes presence at a
    // steady cadence so the cloud + nearby BLE peers always have a fresh
    // timestamp from us.

    private func startPresenceHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard let self else { return }
                self.tickHeartbeat()
            }
        }
    }

    private func stopPresenceHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func tickHeartbeat() {
        guard !myGroups.isEmpty else { return }

        // Adaptive "walk a few steps" prompt: when we're a seeker in
        // an active group and every known peer's last-seen has gone
        // stale, the compass arrow is decaying. Schedule a notification
        // asking the user to move. Cancelled on the next fresh peer
        // update via `mergeBLEPeer`.
        checkPeerStalenessForPrompt()

        // Skip if a real location fix already kept us fresh — keeps the
        // CloudKit write rate from doubling when we're moving.
        let now = Date()
        guard now.timeIntervalSince(currentUser.lastSeen) > Self.heartbeatStaleAfter else {
            return
        }

        // Local-self refresh so the live currentUser stays fresh for
        // any UI bound to it.
        var refreshedSelf = currentUser
        refreshedSelf.lastSeen = now
        currentUser = refreshedSelf

        // Refresh and re-publish a per-group user record for every
        // membership. Each group has its own User.id (per-group UUID),
        // so we mint a fresh User for each group using that group's
        // membership ID. `User.id` is a `let`, hence the construction
        // via init rather than mutation.
        for group in myGroups {
            guard let myID = membershipByGroupID[group.id] else { continue }

            var perGroupSelf = User(
                id: myID,
                displayName: refreshedSelf.displayName,
                avatarData: refreshedSelf.avatarData,
                lastSeen: refreshedSelf.lastSeen,
                coordinate: refreshedSelf.coordinate,
                heading: refreshedSelf.heading,
                nearbyToken: refreshedSelf.nearbyToken,
                banHash: nil,
                eventCursor: eventCursors[group.id]
            )
            // Use the existing on-record banHash for this group if any,
            // otherwise stamp a fresh one. Older memberships created
            // before the ban feature shipped pick the hash up on the
            // first heartbeat.
            let storedHash = group.members.first(where: { $0.id == myID })?.banHash
            perGroupSelf.banHash = storedHash
                ?? stampBanHash(perGroupSelf, for: group).banHash

            // Hypothetical-source tagging (B.2.2): if we've never had
            // GPS during this app session, our heartbeat advertises
            // `.hypothetical` so other members render us with the
            // indoor / no-coords styling instead of pretending we
            // have a real fix. Once GPS lands the location consumer
            // overwrites this with `.gps` (or `.deadReckoning`).
            if !hasEverHadGPSThisSession {
                perGroupSelf.positionSource = .hypothetical
                perGroupSelf.positionAnchorAt = nil
                perGroupSelf.accuracy = nil
            }

            // Patch the cached group + myGroups list in-place so the
            // UI reflects the heartbeat before the network call lands.
            var patched = group
            if let idx = patched.members.firstIndex(where: { $0.id == myID }) {
                patched.members[idx] = perGroupSelf
            } else {
                patched.members.append(perGroupSelf)
            }
            addOrUpdate(group: patched)
            if currentGroup?.id == group.id {
                currentGroup = patched
            }

            // Background write — fire-and-forget per group. We don't
            // serialize because most of the cost is network latency
            // and the writes are independent.
            Task { [groupService = self.groupService, perGroupSelf, patched] in
                try? await groupService.publish(user: perGroupSelf, in: patched)
            }
        }

        // Bypass the 10s `publishLocationIfNeeded` throttle since the
        // heartbeat is itself the cadence we want.
        lastLocationPublishAt = now
        broadcastBLEPresence()
    }

    // MARK: - UWB precision finding

    /// Called by CompassView when the user taps Find on a member.
    /// Starts the local NISession (so we have a token to publish), opens
    /// a peer session against the target's stored token, publishes our
    /// fresh token to CloudKit so the target's app can reciprocate.
    func startUWBTracking(targetMemberID: UUID) {
        // Engage the seeking router — it picks the best channel (UWB
        // when both sides support it + are foregrounded, else
        // Wi-Fi Aware ranging, else BLE active RSSI polling) and
        // forwards samples through the unified `rangingUpdates`
        // stream consumed by `seekingRouterTask`. UWB token plumbing
        // below stays even on non-UWB devices because peers may yet
        // upgrade and the router will re-pick once capability flips.
        seekingRouter.engage(targetMemberID: targetMemberID)

        guard uwbSessionService.isSupported else { return }
        uwbSessionService.start()

        // Publish the fresh token so the peer can fetch it on their next
        // refresh / push and start a session targeting us.
        if let tokenData = uwbSessionService.localTokenData {
            currentUser.nearbyToken = tokenData
            if var group = currentGroup,
               let idx = group.members.firstIndex(where: { $0.id == currentUser.id }) {
                group.members[idx].nearbyToken = tokenData
                currentGroup = group
                addOrUpdate(group: group)
                let me = currentUser
                Task { [groupService = self.groupService, me, group] in
                    try? await groupService.publish(user: me, in: group)
                }
            }
        }

        // If we already have the target's token cached, start the
        // peer session immediately. Otherwise the next CloudKit refresh
        // will surface it and we'll wire it up at that point.
        if let group = currentGroup,
           let target = group.members.first(where: { $0.id == targetMemberID }),
           let theirToken = target.nearbyToken {
            uwbSessionService.track(memberID: targetMemberID, tokenData: theirToken)
        }
    }

    /// Called when the compass view dismisses. Tears down UWB sessions
    /// and clears local readings so a re-open starts fresh.
    func stopUWBTracking() {
        seekingRouter.stop()
        uwbSessionService.stop()
        uwbReadings.removeAll()
        // Clear our published token. Peers fetching after this point
        // get a stale-token failure rather than a phantom session.
        currentUser.nearbyToken = nil
        if var group = currentGroup,
           let idx = group.members.firstIndex(where: { $0.id == currentUser.id }) {
            group.members[idx].nearbyToken = nil
            currentGroup = group
            addOrUpdate(group: group)
            let me = currentUser
            Task { [groupService = self.groupService, me, group] in
                try? await groupService.publish(user: me, in: group)
            }
        }
    }

    // MARK: - CloudKit subscriptions

    /// CloudKit delivers `CKQuerySubscription` updates as silent APNs
    /// pushes. AppDelegate yields each one to a static AsyncStream and
    /// we consume it here, refreshing the active group so the existing
    /// newest-wins merge surfaces the new data.
    ///
    /// Why two refreshes per push: CKQuerySubscription fires on record
    /// *creation*, which can beat the public-DB *index* by 1–3 seconds.
    /// The first refresh sometimes returns stale results that miss the
    /// just-arrived record. A second refresh a few seconds later picks
    /// up records the index has finished propagating. Cheap insurance
    /// against the most common "I got the notification but the member
    /// isn't on my screen" symptom.
    private func startPushHandler() {
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            for await _ in AppDelegate.pushStream {
                guard let self else { return }
                await self.refreshCurrentGroup()
                // Pull any new events that arrived for the active
                // group. The push could be for either a Member record
                // change (presence) or an Event record creation —
                // we don't currently distinguish, so we run both
                // sync paths every time.
                if let activeID = self.currentGroup?.id {
                    await self.syncEvents(for: activeID)
                }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await self.refreshCurrentGroup()
                if let activeID = self.currentGroup?.id {
                    await self.syncEvents(for: activeID)
                }
            }
        }
    }

    // MARK: - Identity

    /// Resolve the stable identifier used as the salt input for the
    /// per-group ban hash. Backed by `LocalIdentityStore` (Keychain),
    /// so:
    ///   • Works offline / signed out of iCloud — no CloudKit round-
    ///     trip required, just a synchronous Keychain read.
    ///   • Survives reinstall on the same device — closes the
    ///     trivial "ban evasion via reinstall" exploit that the
    ///     UserDefaults-backed identity had.
    ///   • Syncs across the user's other devices on the same Apple
    ///     ID via iCloud Keychain, so a ban applies to all of their
    ///     devices, not just the one it was issued on.
    ///
    /// The backend's `cloudUserID()` (CKUserRecordID for the cloud
    /// backend, per-install UUID for local) is now legacy — kept on
    /// the protocol for compatibility but no longer the source of
    /// identity. Re-resolved on `CKAccountChanged` so an account
    /// switch invalidates the cached value (the Keychain item itself
    /// doesn't change, but the call re-reads it for clarity).
    private func loadLocalCloudUserID() {
        self.localCloudUserID = LocalIdentityStore.stableID()
    }

    /// SHA-256 hash for the local user against a given invite code.
    /// Returns nil if we don't yet have a cached cloud ID — callers
    /// must treat that as "ban enforcement unavailable for this
    /// session" and degrade gracefully (don't silently let banned
    /// users back in; instead refuse to join until the ID resolves).
    func localBanHash(forInviteCode inviteCode: String) -> String? {
        guard let cloudID = localCloudUserID else { return nil }
        return BanHash.compute(cloudUserID: cloudID, inviteCode: inviteCode)
    }

    /// True if the local user's hash appears in the given group's
    /// banlist. Used by the join flow (pre-publish gate) and by
    /// `refreshCurrentGroup` (detect that we've been kicked).
    func isLocalUserBanned(from group: GroupSession) -> Bool {
        guard let myHash = localBanHash(forInviteCode: group.inviteCode) else {
            return false
        }
        return group.bannedMembers.contains(where: { $0.banHash == myHash })
    }

    /// Refresh the iCloud account status now and again every time the
    /// system fires `CKAccountChanged` (e.g. user signs in/out from
    /// Settings while we're running). Surfaced via `iCloudAccountStatus`
    /// for the Home banner.
    private func startICloudAccountMonitor() {
        // Initial fetch so the banner reflects reality before the user
        // even taps anything.
        Task { [weak self] in
            guard let self else { return }
            let status = await self.groupService.iCloudAccountStatus()
            self.iCloudAccountStatus = status
        }
        guard iCloudAccountChangeTask == nil else { return }
        iCloudAccountChangeTask = Task { [weak self] in
            // Use the raw name string to avoid importing CloudKit just
            // for the notification constant. CloudKit posts this whenever
            // the signed-in iCloud account changes (sign-in, sign-out,
            // account-switch in Settings).
            let name = Notification.Name("CKAccountChanged")
            let notifications = NotificationCenter.default.notifications(named: name)
            for await _ in notifications {
                guard let self else { return }
                let status = await self.groupService.iCloudAccountStatus()
                self.iCloudAccountStatus = status
                // Account switch invalidates the cached cloud ID — the
                // user's hash for any active group is now wrong. Drop
                // the cache and refetch so subsequent ban checks use
                // the right identity.
                self.localCloudUserID = nil
                self.loadLocalCloudUserID()
            }
        }
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

    /// Returns a copy of `user` with the per-group ban hash stamped
    /// in. Called from create / join flows just before publishing the
    /// user record, so the owner has the hash on hand if they later
    /// remove this member. If we don't yet have a cached cloud ID
    /// (offline, signed out), the hash stays nil — the local user
    /// can still participate, they just can't be banned, which is
    /// also true if they reinstall later, so this is consistent.
    func stampBanHash(_ user: User, for group: GroupSession) -> User {
        var copy = user
        copy.banHash = localBanHash(forInviteCode: group.inviteCode)
        return copy
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
        let isOwner = group.ownerID == currentUser.id

        if isOwner {
            // Owner-initiated hard delete. Emit `.groupDeleted` FIRST
            // so the event lands in the persisted log + pending-emits
            // queue + BLE gossip stream before we tear down local
            // state. Non-owner peers reduce this event into "drop the
            // group locally and show a notice" — see
            // `applyEventSideEffects(_:)`.
            emit(.groupDeleted, in: group.id)

            myGroups.removeAll { $0.id == group.id }
            membershipByGroupID.removeValue(forKey: group.id)
            if currentGroup?.id == group.id {
                currentGroup = nil
            }
            Task { [notificationService, groupID = group.id] in
                await notificationService.cancelAll(for: groupID)
            }
            Task { [groupService = self.groupService, groupID = group.id] in
                try? await groupService.deleteGroup(groupID: groupID)
            }
        } else {
            // Non-owner — route through the voluntary-leave path so
            // the member record is actually removed from CloudKit
            // and other members stop seeing a ghost membership.
            Task { [groupID = group.id] in
                await self.removeMyselfFromGroup(groupID)
            }
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

    /// Pops the dashboard back to Home **without** tearing down any
    /// tracking. The user remains a member of the group; location,
    /// beacon monitoring, heartbeat, and CloudKit subscriptions all
    /// keep running because they're scoped to `myGroups`. `currentGroup`
    /// stays set so re-opening the same group is instant.
    func closeDashboard() {
        path.removeAll()
    }

    /// Voluntary leave. Deletes this device's member record from the
    /// group server-side (without writing to the banlist — voluntary
    /// leaves aren't bans), drops the group from local state, and
    /// pops back to Home. Safe to call from anywhere; ownership is
    /// checked upstream because owners delete the whole group, they
    /// don't leave.
    func removeMyselfFromGroup(_ groupID: UUID) async {
        guard let memberID = membershipByGroupID[groupID],
              let group = myGroups.first(where: { $0.id == groupID }) else { return }

        // Emit the event first — even if the server-side delete
        // below fails, other members will see we left via the event
        // log on their next sync. The event log is the authoritative
        // record of group changes; the User-record delete is just a
        // cleanup detail.
        emit(.memberLeft(memberID: memberID), in: groupID)

        // Server-side delete. If it fails, we still tear down local
        // state so the user doesn't get stuck with a ghost group —
        // the server-side record will be cleaned up on the next
        // refresh / by expiry.
        do {
            try await groupService.leaveGroup(groupID: groupID, memberID: memberID)
        } catch {
            // Swallow — the local teardown below is still the right
            // user-facing outcome.
        }

        // Local teardown — drop the group from every cache that
        // referenced it. This is the same shape as `remove(group:)`
        // for the non-owner case, but kept as its own entry point so
        // call sites can be specific about intent.
        myGroups.removeAll { $0.id == groupID }
        membershipByGroupID.removeValue(forKey: groupID)
        if currentGroup?.id == groupID {
            currentGroup = nil
        }
        // Drop per-peer transport / UWB caches scoped to ex-members.
        for member in group.members where member.id != currentUser.id {
            peerSources.removeValue(forKey: member.id)
            uwbReadings.removeValue(forKey: member.id)
        }
        // Cancel any pending notifications for this group so the user
        // isn't surprised by a stale "30 minutes left" reminder.
        Task { [notificationService, groupID] in
            await notificationService.cancelAll(for: groupID)
        }
        path.removeAll()
    }

    /// Owner-only kick. Removes the target member's record from the
    /// backend and updates local state so the dashboard reflects the
    /// change immediately. Silently no-ops if the local user isn't
    /// the group owner — the UI shouldn't even surface the option to
    /// non-owners, but this is a defense-in-depth check.
    func removeMember(_ memberID: UUID) async {
        guard let group = currentGroup,
              group.ownerID == currentUser.id,
              memberID != currentUser.id else { return }

        // Snapshot the kicked member's details so the event + banlist
        // entry are complete regardless of subsequent state reads.
        let kicked = group.members.first(where: { $0.id == memberID })
        let displayName = kicked?.displayName ?? "Member"
        let banHash = kicked?.banHash

        // Offline-first: update local state immediately so the owner
        // sees the kick happen instantly even with no network. The
        // event log + cloud snapshot save are best-effort follow-ups.
        var updated = group
        updated.members.removeAll { $0.id == memberID }
        if let hash = banHash,
           !updated.bannedMembers.contains(where: { $0.banHash == hash }) {
            updated.bannedMembers.append(BannedMember(
                banHash: hash,
                displayName: displayName,
                bannedAt: .now
            ))
        }
        currentGroup = updated
        addOrUpdate(group: updated)

        // Drop the now-stale per-peer tracking so the UI isn't
        // briefly trying to render a member who's no longer in the
        // list.
        peerSources.removeValue(forKey: memberID)
        uwbReadings.removeValue(forKey: memberID)

        // Authoritative record of the kick — event log, retried via
        // pendingEmits + BLE gossiped. Other devices reduce this
        // event into their own state when it reaches them.
        emit(.memberRemoved(
            memberID: memberID,
            displayName: displayName,
            banHash: banHash
        ), in: group.id)

        // Cloud snapshot update — writes the new banlist arrays to
        // the Group CKRecord so new joiners are rejected. Routed
        // through `dispatchGroupSave` which retries on failure via
        // pendingGroupSaves, so the cloud catches up whenever
        // network returns.
        dispatchGroupSave(updated)

        // Best-effort delete of the kicked member's CKRecord. If this
        // fails the record orphan-persists in CloudKit until the
        // group itself is deleted (the .deleteSelf reference action
        // cascades). The visible kick still works because:
        //   • Other members see the `memberRemoved` event and reduce.
        //   • Cloud Group record's banlist is updated via
        //     dispatchGroupSave, so refresh filters re-add by hash.
        //   • New joiners are rejected at the banlist gate.
        // Privacy cleanup of the orphan record is a follow-up.
        Task { [groupService, memberID, groupID = group.id] in
            try? await groupService.removeMember(
                memberID: memberID, fromGroup: groupID
            )
        }
    }

    /// Owner-only unban. Reverses a previous removal so the named
    /// person can rejoin with the invite code. Like `removeMember`,
    /// double-checks ownership defensively.
    ///
    /// Offline-first: local banlist is mutated immediately and the
    /// event is emitted (queued via `pendingEmits` if CloudKit is
    /// unreachable). The cloud snapshot save also routes through
    /// `dispatchGroupSave` so the banlist on the Group CKRecord
    /// catches up whenever connectivity returns.
    func unbanMember(banHash: String) async {
        guard let group = currentGroup,
              group.ownerID == currentUser.id else { return }

        var updated = group
        updated.bannedMembers.removeAll { $0.banHash == banHash }
        currentGroup = updated
        addOrUpdate(group: updated)

        // Authoritative record of the unban — retried via
        // pendingEmits + BLE gossiped to in-range peers.
        emit(.memberUnbanned(banHash: banHash), in: group.id)

        // Cloud snapshot — writes the updated banlist arrays back to
        // the Group CKRecord so the next refresh doesn't re-import
        // the stale ban hash.
        dispatchGroupSave(updated)

        // Best-effort direct call to the typed unban endpoint. If it
        // fails the dispatchGroupSave above is the durable path.
        Task { [groupService, banHash, groupID = group.id] in
            _ = try? await groupService.unbanMember(
                banHash: banHash, fromGroup: groupID
            )
        }
    }

    // MARK: - Location lifecycle

    func startLocationTracking() {
        locationService.requestAuthorization()
        locationService.startUpdating()

        // Adaptive accuracy: when motion classifies us as stationary,
        // drop GPS budget to save battery; bump back to best when we
        // start moving again.
        motionService.start()
        if motionTask == nil {
            motionTask = Task { [weak self] in
                guard let self else { return }
                for await stationary in self.motionService.stationaryUpdates {
                    self.locationService.adjustForMotion(stationary: stationary)
                }
            }
        }

        if locationTask == nil {
            locationTask = Task { [weak self] in
                guard let self else { return }
                for await fix in self.locationService.locationUpdates {
                    // Stamp full provenance on every fresh fix:
                    // source = .gps with the accuracy CoreLocation
                    // reported. Downstream readers can degrade to
                    // .staleGPS via `User.positionEstimate` when the
                    // fix gets old.
                    var me = self.currentUser
                    me.coordinate = fix.coordinate
                    me.accuracy = fix.accuracy
                    me.positionSource = .gps
                    me.positionAnchorAt = fix.timestamp
                    me.positionSourcePeerID = nil
                    me.lastSeen = .now
                    self.currentUser = me

                    // GPS-state bookkeeping for the DR / hypothetical
                    // decision logic: remember when the latest fresh
                    // fix landed, and note that we've had GPS at
                    // least once this session.
                    self.lastGPSFixAt = fix.timestamp
                    self.hasEverHadGPSThisSession = true

                    // Re-anchor the dead-reckoning service. Each fresh
                    // GPS fix becomes the new anchor; the prior
                    // pedometer window also feeds calibration of the
                    // user's personal step length.
                    self.deadReckoningService.reanchor(to: fix)

                    // Feed the gradient engine so the compass can fall
                    // back to RSSI-based bearing when GPS isn't viable.
                    self.compassEngine.recordPosition(
                        latitude: fix.coordinate.latitude,
                        longitude: fix.coordinate.longitude
                    )

                    // Propagate the fresh provenance into the active
                    // group's member entry as well. The per-group
                    // membership UUIDs differ from `currentUser.id`
                    // for multi-group setups, so look up via the
                    // membership map and patch only the local cache;
                    // the publish path below handles every group.
                    if var group = self.currentGroup,
                       let myID = self.membershipByGroupID[group.id],
                       let idx = group.members.firstIndex(where: { $0.id == myID }) {
                        var perGroup = group.members[idx]
                        perGroup.coordinate = fix.coordinate
                        perGroup.accuracy = fix.accuracy
                        perGroup.positionSource = .gps
                        perGroup.positionAnchorAt = fix.timestamp
                        perGroup.lastSeen = me.lastSeen
                        group.members[idx] = perGroup
                        self.currentGroup = group
                        self.addOrUpdate(group: group)

                        self.publishLocationIfNeeded(member: perGroup, in: group)
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

                    // Feed DR so step-projection uses the latest
                    // compass direction. Heading updates are far
                    // more frequent than pedometer ticks, so this
                    // keeps the projected vector aligned with the
                    // user's actual motion.
                    self.deadReckoningService.updateHeading(smoothed)

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

        if deadReckoningTask == nil {
            deadReckoningTask = Task { [weak self] in
                guard let self else { return }
                for await estimate in self.deadReckoningService.positionUpdates {
                    self.applyDeadReckoning(estimate)
                }
            }
        }

        // Start CMPedometer step observation independent of GPS
        // anchor. The compass engine consumes step deltas to advance
        // synthetic positions for the indoor gradient — the only
        // mechanism that survives no-GPS + no-DR-anchor environments.
        deadReckoningService.startStepObservation()

        if compassStepTask == nil {
            compassStepTask = Task { [weak self] in
                guard let self else { return }
                let stride = self.deadReckoningService.calibratedStepLength
                for await delta in self.deadReckoningService.stepUpdates {
                    let heading = self.currentUser.heading ?? 0
                    let displacement = Double(delta) * stride
                    self.compassEngine.recordStep(
                        headingDegrees: heading,
                        stepLengthMetres: displacement
                    )
                }
            }
        }
    }

    /// Apply a DR estimate to local state — but only when GPS is
    /// stale. While fresh GPS is firing we ignore DR (the GPS path
    /// already covers us with better data and freshly-anchored
    /// provenance). The check is on `lastGPSFixAt` rather than the
    /// in-memory User's `lastSeen` because the heartbeat refreshes
    /// `lastSeen` even when no new GPS arrived.
    private func applyDeadReckoning(_ estimate: PositionEstimate) {
        let now = Date()
        let lastFix = lastGPSFixAt ?? .distantPast
        guard now.timeIntervalSince(lastFix) > Self.gpsStaleAfter else { return }

        var me = currentUser
        me.coordinate = estimate.coordinate
        me.accuracy = estimate.accuracy
        me.positionSource = .deadReckoning
        me.positionAnchorAt = estimate.anchorAt
        me.lastSeen = estimate.computedAt
        currentUser = me

        compassEngine.recordPosition(
            latitude: estimate.coordinate.latitude,
            longitude: estimate.coordinate.longitude
        )

        // Patch the active group's member entry + push the next
        // BLE/CloudKit broadcast so peers see the DR position
        // immediately. The same per-group lookup as the GPS path —
        // membershipByGroupID gives us the right member ID for
        // multi-group setups.
        guard var group = currentGroup,
              let myID = membershipByGroupID[group.id],
              let idx = group.members.firstIndex(where: { $0.id == myID }) else {
            return
        }
        var perGroup = group.members[idx]
        perGroup.coordinate = estimate.coordinate
        perGroup.accuracy = estimate.accuracy
        perGroup.positionSource = .deadReckoning
        perGroup.positionAnchorAt = estimate.anchorAt
        perGroup.lastSeen = me.lastSeen
        group.members[idx] = perGroup
        currentGroup = group
        addOrUpdate(group: group)

        publishLocationIfNeeded(member: perGroup, in: group)
        broadcastBLEPresence()
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
        motionService.stop()
        deadReckoningService.stop()
        compassStepTask?.cancel()
        compassStepTask = nil
        // Reset session GPS state — leaving all groups means the next
        // membership starts fresh. Without this, a second "join later"
        // session would still think we'd had GPS at some point.
        hasEverHadGPSThisSession = false
        lastGPSFixAt = nil
        // Ensure we're in best-accuracy mode for the next session;
        // otherwise a stale "stationary" decision could carry over.
        locationService.adjustForMotion(stationary: false)
    }

    // MARK: - BLE peer presence

    /// Start broadcasting + scanning for nearby group members over BLE.
    /// Pairs with `stopBLEPresence()` on dashboard disappear. Also
    /// brings up the payload transport (chat + event-log gossip) under
    /// the group's rendezvous token; BLE only carries the heartbeat
    /// and join handshake.
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

        if seekingRouterTask == nil {
            seekingRouterTask = Task { [weak self] in
                guard let self else { return }
                for await sample in self.seekingRouter.rangingUpdates {
                    self.handleRangingSample(sample)
                }
            }
        }

        startPayloadTransport(for: group)
    }

    /// Dispatch a ranging sample from the seeking router into the
    /// right downstream consumer. RSSI samples feed the compass
    /// engine's gradient regression; UWB samples land in
    /// `uwbReadings` so the compass dial's UWB-first cascade picks
    /// them up. Wi-Fi Aware samples (when wired) carry both fields
    /// and fan out to both consumers.
    private func handleRangingSample(_ sample: RangingSample) {
        if let rssi = sample.rssi {
            compassEngine.recordRSSI(rssi, for: sample.memberID)
        }
        if sample.distance != nil || sample.direction != nil {
            uwbReadings[sample.memberID] = UWBReading(
                memberID: sample.memberID,
                distance: sample.distance,
                direction: sample.direction,
                timestamp: sample.timestamp
            )
        }
    }

    /// Bring up the payload transport for `group` and start consuming
    /// incoming frames. Idempotent: a no-op if already running for the
    /// same group; a clean restart if the group changed.
    ///
    /// Sought role doesn't spin the transport up — a backgrounded user
    /// only needs to be *findable* over BLE; the transport comes alive
    /// when they foreground (and the role flips to seeker) or when an
    /// in-range seeker wakes them via state restoration.
    private func startPayloadTransport(for group: GroupSession) {
        guard role == .seeker else { return }
        if activeTransportGroupID == group.id { return }

        let displayName = (membershipByGroupID[group.id] ?? currentUser.id)
            .uuidString
        let rendezvous = Self.rendezvousToken(forInviteCode: group.inviteCode)

        payloadTransport.stop()
        payloadIncomingTask?.cancel()
        payloadIncomingTask = nil

        payloadTransport.start(displayName: displayName, rendezvousToken: rendezvous)
        activeTransportGroupID = group.id

        payloadIncomingTask = Task { [weak self] in
            guard let self else { return }
            for await packet in self.payloadTransport.incoming {
                guard let frame = PayloadFrame.decode(from: packet.data) else { continue }
                switch frame {
                case .event(let event):
                    self.handleGossipedEvent(event)
                }
            }
        }
    }

    /// Tear down the payload transport. Safe to call when not running.
    private func stopPayloadTransport() {
        payloadTransport.stop()
        payloadIncomingTask?.cancel()
        payloadIncomingTask = nil
        activeTransportGroupID = nil
    }

    /// Derive a short, stable rendezvous token from an invite code.
    /// SHA-256 of a salted form of the invite code, truncated to
    /// 8 bytes / 16 hex chars. Two devices in the same group MUST
    /// compute identical tokens — `MCNearbyServiceBrowser.foundPeer`
    /// rejects every peer whose advertised token doesn't match the
    /// browser's local token, so non-deterministic hashing means
    /// zero connected peers, ever.
    ///
    /// **Don't** use Swift's `Hasher` here: it's intentionally seeded
    /// with a process-random value (per Apple's docs, hashes are not
    /// stable across launches or processes), which means every device
    /// would compute a different token for the same invite code and
    /// the payload transport (chat + event-log gossip) would silently
    /// fail to connect any peer. This was the root cause of "chat
    /// doesn't work" + most of the missing-identity / stale-out
    /// symptoms — events that would carry display names and avatars
    /// never crossed the wire.
    private static func rendezvousToken(forInviteCode inviteCode: String) -> String {
        let salted = "groupin.payload.rdv." + inviteCode.uppercased()
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Peer-staleness threshold for the walk-around prompt. If every
    /// member in the active group has a `lastSeen` older than this,
    /// schedule the prompt. 90 s balances "the user notices we lost
    /// signal" against "we're not nagging during a normal lull."
    private static let peerStalenessThreshold: TimeInterval = 90
    /// Delay before the prompt actually fires after scheduling, giving
    /// the next heartbeat or peer update a chance to cancel it. Keeps
    /// transient gaps from producing noise notifications.
    private static let walkAroundPromptDelay: TimeInterval = 15

    private func checkPeerStalenessForPrompt() {
        guard role == .seeker,
              let group = currentGroup,
              !group.members.isEmpty else { return }
        let myID = membershipByGroupID[group.id]
        let now = Date()
        // Look at members other than ourselves. If they're all stale
        // *and* we have at least one of them tracked, prompt.
        let peers = group.members.filter { $0.id != myID }
        guard !peers.isEmpty else { return }
        let allStale = peers.allSatisfy { peer in
            now.timeIntervalSince(peer.lastSeen) > Self.peerStalenessThreshold
        }
        if allStale {
            Task { [notificationService, groupID = group.id] in
                await notificationService.scheduleWalkAroundPrompt(
                    for: groupID,
                    after: Self.walkAroundPromptDelay
                )
            }
        } else {
            Task { [notificationService, groupID = group.id] in
                await notificationService.cancelWalkAroundPrompt(for: groupID)
            }
        }
    }

    /// Apply a SwiftUI scene-phase change. Foreground → seeker (full
    /// stack). Background / inactive → sought (BLE peripheral keeps
    /// advertising; transport tears down).
    func applyScenePhase(active: Bool) {
        let newRole: Role = active ? .seeker : .sought
        guard newRole != role else { return }
        role = newRole
        switch newRole {
        case .seeker:
            if let group = currentGroup {
                startPayloadTransport(for: group)
            }
        case .sought:
            stopPayloadTransport()
        }
    }

    /// Recompute the group-min transport across the active group's
    /// known peer capabilities + our own, and ask the router to
    /// switch if the answer changed. Called whenever a peer's
    /// advertised capability shifts.
    private func recomputeGroupTransport() {
        guard activeTransportGroupID != nil else { return }
        var all: [TransportCapability] = [Self.localTransportCapability()]
        all.append(contentsOf: peerCapabilities.values)
        if let selection = TransportCapability.groupMinimum(across: all),
           selection != payloadTransport.selection {
            payloadTransport.select(selection)
        }
    }

    /// Apply an event received from BLE gossip. Idempotent: events
    /// we already have advance no state. Events for groups we aren't
    /// a member of are dropped (you're not supposed to receive them,
    /// but BLE traffic could theoretically cross over). For events
    /// we don't have, we append locally, fold into state, and re-
    /// gossip to any in-range peers that are still behind — that's
    /// the transitive relay that makes D→C→B reach B even when only
    /// A originally had the event.
    private func handleGossipedEvent(_ event: Event) {
        // Drop events for groups we don't belong to.
        guard myGroups.contains(where: { $0.id == event.groupID }) else {
            return
        }
        // Dedup at the log level — `ingestEvent` would do this too,
        // but checking here saves the reducer + downstream calls.
        if let existing = eventsByGroup[event.groupID],
           existing.contains(where: { $0.id == event.id }) {
            return
        }
        // Fold into state via the reducer (which also calls
        // `ingestEvent` to update the local log and cursors).
        applyEvents([event], to: event.groupID)

        // Mirror to CloudKit so the event has a durable home too —
        // safe to call even if it landed there originally (the
        // appendEvent path is idempotent on event ID).
        Task { [groupService = self.groupService, event] in
            try? await groupService.appendEvent(event)
        }

        // Re-broadcast onward — closes the relay loop so a third
        // peer in range gets it through us. Cursor-gated, so we
        // skip if everyone we can reach is already caught up.
        broadcastEventIfPeersBehind(event)
    }

    func stopBLEPresence() {
        seekingRouter.stop()
        seekingRouterTask?.cancel()
        seekingRouterTask = nil
        blePresenceService.stop()
        stopPayloadTransport()
    }

    /// Consume the BLE diagnostics stream for the lifetime of the app,
    /// not just while the dashboard is open. The Home status banner
    /// relies on the readiness flag, which can flip at any moment when
    /// the user toggles Bluetooth in Control Center — including before
    /// they've ever opened a group.
    private func startBLEDiagnosticsMonitor() {
        if bleDiagnosticsTask == nil {
            bleDiagnosticsTask = Task { [weak self] in
                guard let self else { return }
                for await diag in self.blePresenceService.diagnostics {
                    self.bleDiagnostics = diag
                }
            }
        }
        if seekingDiagnosticsTask == nil {
            seekingDiagnosticsTask = Task { [weak self] in
                guard let self else { return }
                for await diag in self.seekingRouter.diagnostics {
                    self.seekingDiagnostics = diag
                }
            }
        }
        if transportDiagnosticsTask == nil {
            transportDiagnosticsTask = Task { [weak self] in
                guard let self else { return }
                for await diag in self.payloadTransport.diagnostics {
                    self.transportDiagnostics = diag
                }
            }
        }
    }

    // MARK: - Offline chat

    /// Send a short text message over BLE to nearby group members.
    /// Local echo is appended to `chatMessages` immediately so the
    /// sender sees their own message in the thread without round-tripping.
    func sendChatMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let group = currentGroup else { return }
        // Chat-as-event: emit a `.chatMessage` event through the
        // standard pipeline. Local appending of the event + CloudKit
        // append + BLE gossip all happen via `emit(...)`. The
        // legacy ephemeral chat path is no longer used for sends.
        emit(.chatMessage(text: trimmed), in: group.id)
    }

    private func appendChat(_ message: ChatMessage) {
        // Dedup on id in case we somehow see the same packet twice.
        guard !chatMessages.contains(where: { $0.id == message.id }) else { return }
        chatMessages.append(message)
        if chatMessages.count > Self.chatBufferLimit {
            chatMessages.removeFirst(chatMessages.count - Self.chatBufferLimit)
        }
    }

    private func makeLocalPresence(for group: GroupSession) -> PeerPresence {
        // Use the per-group membership ID, not `currentUser.id` (which
        // is keyed by whatever group is currently in focus). Receivers
        // match on the per-group ID when merging via `mergeBLEPeer`.
        let memberID = membershipByGroupID[group.id] ?? currentUser.id
        return PeerPresence(
            groupHash: PeerPresence.groupHash(forInviteCode: group.inviteCode),
            memberID: memberID,
            // Display name in the presence packet means receivers can
            // render the peer's actual name immediately, without
            // depending on event-log gossip via the payload transport
            // — which is fragile (Local Network permission, peer
            // foreground state, etc). BLE presence is the always-on
            // signaling channel; identity belongs here.
            displayName: localProfile.displayName,
            latitude: currentUser.coordinate?.latitude,
            longitude: currentUser.coordinate?.longitude,
            heading: currentUser.heading,
            lastSeen: currentUser.lastSeen,
            accuracy: currentUser.accuracy,
            positionSource: currentUser.positionSource?.rawValue,
            positionAnchorAt: currentUser.positionAnchorAt,
            eventCursor: eventCursors[group.id],
            transportCapability: Self.localTransportCapability()
        )
    }

    /// Snapshot of this device's transport capabilities for
    /// broadcasting in PeerPresence. The group-min across all
    /// members' snapshots picks the active transport.
    private static func localTransportCapability() -> TransportCapability {
        let wa = WiFiAwareService.deviceSupportsWiFiAware()
        return TransportCapability(
            wifiAware: wa,
            multipeer: true,
            uwb: UWBSessionService.deviceSupportsUWB(),
            // Wi-Fi Aware ranging rides on the same framework + entitlement
            // as the payload transport — same gate today. The seeking
            // router will treat them independently when (later) the
            // entitlement story diverges.
            wifiAwareRanging: wa,
            bleRanging: true
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

        // Transport bookkeeping runs unconditionally — we want the
        // "we're hearing this peer on Bluetooth" signal regardless of
        // whether their full member record has caught up yet.
        recordTransport(.ble, for: peer.memberID)

        // Capability tracking → drives the group-min transport
        // selection. Missing field (older client) is treated as
        // MPC-only, matching the safest fallback.
        let advertised = peer.transportCapability ?? .mpcOnly
        if peerCapabilities[peer.memberID] != advertised {
            peerCapabilities[peer.memberID] = advertised
            recomputeGroupTransport()
            // Seeking router picks per-peer channel based on shared
            // capability bits; feed every new peer-capability decode
            // so handoff can happen the moment a better tier is
            // unlocked (e.g., peer foregrounds and UWB becomes
            // available).
            seekingRouter.setPeerCapability(advertised, for: peer.memberID)
        }

        // Fresh signal from a peer means the staleness window resets —
        // cancel any pending "walk a few steps" prompt.
        if let groupID = currentGroup?.id {
            Task { [notificationService] in
                await notificationService.cancelWalkAroundPrompt(for: groupID)
            }
        }

        // Cursor tracking + cursor-mismatch push run unconditionally
        // too. The BLE service has already verified the peer's
        // groupHash matches our active group, so they're legitimately
        // a member from our perspective — even if our local
        // `members` list hasn't gotten their `memberJoined` event
        // yet (which can happen when CloudKit silent push for
        // memberJoined is delayed or lost). Without this, the first
        // few minutes after a new member joins look like:
        //   1. They have us, see us as a member.
        //   2. We don't have them — `mergeBLEPeer` bailed at the
        //      members-lookup guard, never tracked their cursor.
        //   3. Their chats reach us via their BLE broadcast.
        //   4. Our chats never reach them — empty peerCursors map
        //      means `broadcastEventIfPeersBehind` skips the broadcast.
        //   5. CloudKit push is unreliable enough that the gap
        //      persists indefinitely.
        // Moving cursor tracking out of the guard unsticks all of it.
        if let peerCursor = peer.eventCursor {
            peerCursors[peer.memberID] = peerCursor
            Task { [weak self, groupID = group.id, peerCursor] in
                await self?.pushEventsNewer(than: peerCursor, in: groupID)
            }
        }

        // Member-list update: if we know who this peer is, patch
        // their entry with the fresh BLE data. If we don't, stub a
        // skeleton entry so the dashboard reflects "there's someone
        // in BLE range" while we wait for the `memberJoined` event
        // to arrive and fill in their identity. The reducer will
        // upgrade the stub to a proper entry when the event lands —
        // both paths use the same memberID, so the update merges.
        if let idx = group.members.firstIndex(where: { $0.id == peer.memberID }) {
            guard peer.lastSeen > group.members[idx].lastSeen else {
                currentGroup = group
                addOrUpdate(group: group)
                reevaluateDeliveryStatus(for: group.id)
                return
            }
            group.members[idx].lastSeen = peer.lastSeen
            // If we're still showing the "Member" placeholder for
            // this peer (no memberJoined event ever arrived because
            // MPC was down, say), upgrade the name from the freshly-
            // decoded presence packet. Don't clobber a real name with
            // nil if the peer's payload lacks the field.
            if let name = peer.displayName,
               group.members[idx].displayName == "Member"
                || group.members[idx].displayName.isEmpty {
                group.members[idx].displayName = name
            }
            if let lat = peer.latitude, let lon = peer.longitude {
                group.members[idx].coordinate = Coordinate(latitude: lat, longitude: lon)
            }
            group.members[idx].heading = peer.heading
            group.members[idx].accuracy = peer.accuracy
            group.members[idx].positionSource = peer.positionSource
                .flatMap(PositionSource.init(rawValue:))
            group.members[idx].positionAnchorAt = peer.positionAnchorAt
            group.members[idx].eventCursorCreatedAt = peer.eventCursorCreatedAt
            group.members[idx].eventCursorID = peer.eventCursorID
        } else {
            // Stub a member entry. Use the peer's broadcast display
            // name if present; fall back to a placeholder only if the
            // peer's still on an older build that didn't include the
            // field. The `memberJoined` event later upgrades or
            // confirms via the standard ingest path.
            let stub = User(
                id: peer.memberID,
                displayName: peer.displayName ?? "Member",
                avatarData: nil,
                lastSeen: peer.lastSeen,
                coordinate: (peer.latitude.flatMap { lat in
                    peer.longitude.map { Coordinate(latitude: lat, longitude: $0) }
                }) ?? nil,
                heading: peer.heading,
                nearbyToken: nil,
                banHash: nil,
                accuracy: peer.accuracy,
                positionSource: peer.positionSource
                    .flatMap(PositionSource.init(rawValue:)),
                positionAnchorAt: peer.positionAnchorAt,
                positionSourcePeerID: nil,
                eventCursor: peer.eventCursor
            )
            group.members.append(stub)
        }

        currentGroup = group
        addOrUpdate(group: group)

        // Cursor update may have caught a peer up to one of our
        // outgoing events — promote the delivery status if so.
        reevaluateDeliveryStatus(for: group.id)
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

    /// Public manual-refresh entry point. Triggered by pull-to-refresh
    /// on the dashboard so the user has a way to force a fetch when
    /// the silent-push subscription is delayed or stuck. Returns when
    /// the refresh completes so SwiftUI's `.refreshable` can reset its
    /// progress indicator at the right moment.
    func refreshCurrentGroupManually() async {
        await refreshCurrentGroup()
        if let group = currentGroup {
            await syncEvents(for: group.id)
        }
    }

    // MARK: - Event log integration

    /// Fire-and-forget event emission. The event is appended to the
    /// group's CloudKit log in the background **and** broadcast over
    /// BLE to any in-range peers whose cursors are behind the new
    /// event. If the CloudKit append fails the BLE gossip path still
    /// delivers to nearby peers; if BLE fails (no peers in range) the
    /// CloudKit path still delivers when peers come back online.
    /// Belt and suspenders.
    func emit(_ payload: EventPayload, in groupID: UUID) {
        // For chat-specific payloads we want the author to be the
        // per-group membership ID, not whichever id `currentUser`
        // happens to carry. Other payload types use the same value
        // since they're always emitted in the active-group context
        // (where currentUser.id matches the per-group ID anyway).
        let authorID = membershipByGroupID[groupID] ?? currentUser.id

        let event = Event(
            groupID: groupID,
            authorID: authorID,
            payload: payload
        )
        emit(event)
    }

    /// Sibling to `emit(_:in:)` that takes a fully-constructed Event.
    /// Used when the caller needs a deterministic event ID — most
    /// notably the two-way join handshake, where the joiner and the
    /// BLE responder both emit the same `memberJoined` with a
    /// `(groupID, memberID)`-derived ID so the ingest-level dedup
    /// collapses them into a single log entry / timeline row.
    func emit(_ event: Event) {
        // Append to the local event log right away so the timeline UI
        // reflects the emission instantly. Also advances the latest
        // cursor — we authored this event, we definitely "know" it.
        ingestEvent(event)

        // Delivery tracking starts at .pending. The CloudKit task
        // below advances to .cloud on success; the sync paths advance
        // to .delivered once every other member's cursor is past it.
        advanceDelivery(event.id, to: .pending)

        // CloudKit append — try once optimistically. On failure,
        // enqueue for the retry task which drains on exponential
        // backoff. The persisted queue survives force-quit so an
        // event sent while offline still propagates on next launch.
        Task { [weak self, event] in
            guard let self else { return }
            let succeeded = await self.attemptCloudEmit(event)
            if !succeeded {
                self.enqueueRetry(event)
            }
        }

        // BLE gossip — always broadcast our own emits. Receivers
        // dedup at the event-ID layer, so the only cost of an
        // unnecessary broadcast is the bandwidth of one ~150-byte
        // GATT write. Skipping the gate here is what unblocks the
        // "first chat after a peer joins" path, where their cursor
        // hasn't reached us yet.
        broadcastLocalEmit(event)
    }

    // MARK: - BLE join-request responder (peripheral side)

    /// Long-lived consumer of `blePresenceService.incomingJoinRequests`.
    /// Always running — even before the local user is in a group —
    /// because as soon as we join one we want to immediately respond
    /// to nearby joiners hunting for the same invite code. Skipping
    /// the active-group filter is safe: if no group of ours matches
    /// the request's invite code, we just don't respond.
    private func startJoinRequestResponder() {
        guard bleJoinRequestTask == nil else { return }
        bleJoinRequestTask = Task { [weak self] in
            guard let self else { return }
            for await request in self.blePresenceService.incomingJoinRequests {
                self.handleIncomingJoinRequest(request)
            }
        }
    }

    /// Validate an incoming `JoinRequest` against our memberships and
    /// reply with a `JoinResponse` if there's a match. Banlist check
    /// happens at the request layer (the request carries the
    /// joiner's salted hash) so we can refuse pre-banned joiners
    /// before any group identity leaves our device.
    private func handleIncomingJoinRequest(_ request: JoinRequest) {
        let normalized = request.inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard let group = myGroups.first(where: {
            $0.inviteCode.uppercased() == normalized
        }) else { return }

        if let hash = request.joinerBanHash,
           group.bannedMembers.contains(where: { $0.banHash == hash }) {
            return
        }

        // Two-way commit: mirror the joiner into our local member
        // list and emit `memberJoined` on their behalf BEFORE we
        // ship the JoinResponse. Without this, the responder is
        // relying on the joiner's own `memberJoined` event arriving
        // via gossip — but BLE may drop after the response, or the
        // joiner may walk out of range before their emit lands.
        // Now both sides converge to the same membership even if
        // no further packets cross the wire.
        //
        // The emit uses a deterministic event ID derived from
        // `(groupID, joinerMemberID)`, so when the joiner's own
        // emit also lands, ingestEvent's id-level dedup collapses
        // the pair into one log entry (and one timeline row).
        commitJoinerLocally(request: request, group: group)

        let response = JoinResponse(
            groupID: group.id,
            name: group.name,
            inviteCode: group.inviteCode,
            category: group.category.rawValue,
            ownerID: group.ownerID,
            createdAt: group.createdAt,
            expiresAt: group.expiresAt,
            responderMemberID: membershipByGroupID[group.id] ?? currentUser.id,
            // Send our display name back so the joiner can show our
            // actual name in their member list immediately. Without
            // this they show a "Member" placeholder until event-log
            // gossip arrives, which depends on MPC being up.
            responderDisplayName: localProfile.displayName
        )
        blePresenceService.respondToJoinRequest(response)
    }

    /// Adds the BLE joiner to our local group state and emits a
    /// `memberJoined` event on their behalf. Idempotent — re-applying
    /// for the same joiner (e.g. on a duplicate JoinRequest packet)
    /// is a no-op. See `handleIncomingJoinRequest` for the rationale.
    private func commitJoinerLocally(request: JoinRequest, group: GroupSession) {
        if group.members.contains(where: { $0.id == request.joinerMemberID }) {
            return
        }

        var working = group
        let stub = User(
            id: request.joinerMemberID,
            displayName: request.joinerDisplayName,
            avatarData: nil,
            banHash: request.joinerBanHash
        )
        working.members.append(stub)
        addOrUpdate(group: working)
        if currentGroup?.id == working.id {
            currentGroup = working
        }

        // Emit with author = joiner so the timeline reads "Alice
        // joined" attributed to Alice, not to us. Deterministic
        // event ID collapses against the joiner's own future emit
        // at ingest.
        let eventID = Event.memberJoinedEventID(
            groupID: working.id,
            memberID: request.joinerMemberID
        )
        let event = Event(
            id: eventID,
            groupID: working.id,
            authorID: request.joinerMemberID,
            createdAt: .now,
            payload: .memberJoined(
                memberID: request.joinerMemberID,
                displayName: request.joinerDisplayName,
                avatarData: nil,
                banHash: request.joinerBanHash
            )
        )
        emit(event)
    }

    // MARK: - BLE join discovery (joiner side)

    /// Spin up BLE in join-discovery mode for the given invite code.
    /// Used in parallel with the CloudKit join attempt so an in-range
    /// member can answer instantly even if CloudKit is unreachable.
    /// Returns the next valid `JoinResponse` matching `inviteCode`,
    /// or nil if the calling task is cancelled before any response
    /// arrives.
    /// Tear down any in-flight BLE join discovery — used by the join
    /// view model on Cancel and on timeout so the central stops
    /// writing JoinRequests to every in-range peripheral. Idempotent.
    func cancelBLEJoinDiscovery() {
        blePresenceService.stopJoinDiscovery()
    }

    func awaitBLEJoinResponse(forInviteCode inviteCode: String,
                              joiner: User) async -> JoinResponse? {
        let banHash = localBanHash(forInviteCode: inviteCode)
        let request = JoinRequest(
            inviteCode: inviteCode,
            joinerBanHash: banHash,
            joinerMemberID: joiner.id,
            joinerDisplayName: joiner.displayName
        )
        blePresenceService.startJoinDiscovery(request)

        // Single-consumer continuation. The previous for-await on
        // `blePresenceService.joinResponses` was a shared AsyncStream;
        // a cancelled-but-still-suspended iterator and a new attempt's
        // iterator would race for the same yielded JoinResponse, and
        // the cancelled one frequently won (calling stopJoinDiscovery
        // and clearing pendingJoinRequest before the new task could
        // see anything). Routing through a single replaceable handler
        // makes the delivery deterministic: each new awaiter overrides
        // the prior handler, and cancellation cleanly resumes with nil
        // exactly once.
        let box = ResumeBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<JoinResponse?, Never>) in
                box.install(continuation: continuation)
                self.blePresenceService.setJoinResponseHandler { [weak self, box] response in
                    guard response.inviteCode == inviteCode else { return }
                    Task { @MainActor [weak self, box] in
                        self?.blePresenceService.setJoinResponseHandler(nil)
                        self?.blePresenceService.stopJoinDiscovery()
                        box.resume(with: response)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, box] in
                self?.blePresenceService.setJoinResponseHandler(nil)
                self?.blePresenceService.stopJoinDiscovery()
                box.resume(with: nil)
            }
        }
    }

    /// Thread-safe one-shot continuation resume. Wraps a
    /// `CheckedContinuation` with a lock so concurrent code paths
    /// (handler delivery + cancellation) can race to resume without
    /// double-resume crashes — first call wins, rest no-op. Installed
    /// after construction so the box can be captured by both the
    /// onCancel handler and the inner withCheckedContinuation closure
    /// without ordering pain.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<JoinResponse?, Never>?

        init() {}

        func install(continuation: CheckedContinuation<JoinResponse?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(with value: JoinResponse?) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }
    }

    /// One-shot CloudKit append attempt with delivery-status
    /// bookkeeping. Returns true on success so the caller can
    /// decide whether to enqueue for retry. Used by both the
    /// optimistic `emit` path and the retry-loop drain.
    private func attemptCloudEmit(_ event: Event) async -> Bool {
        do {
            try await groupService.appendEvent(event)
            advanceDelivery(event.id, to: .cloud)
            // After cloud-append, our own cursor on the per-group
            // User record won't reflect this event until the next
            // heartbeat. Push a delivery re-evaluation just in case
            // other members already happen to be ahead.
            reevaluateDeliveryStatus(for: event.groupID)
            return true
        } catch {
            return false
        }
    }

    /// Add an event to the persisted retry queue. Idempotent — a
    /// re-enqueue of the same event ID is a no-op (the existing
    /// entry's backoff is what matters). First retry attempt fires
    /// 5 seconds from now.
    private func enqueueRetry(_ event: Event) {
        guard !pendingEmits.contains(where: { $0.event.id == event.id }) else {
            return
        }
        let entry = PendingEmit(
            event: event,
            retryCount: 0,
            nextRetryAt: Date().addingTimeInterval(PendingEmit.backoff(after: 0))
        )
        pendingEmits.append(entry)
    }

    /// Long-lived retry loop. Wakes every `retryTickInterval`, drains
    /// any pending emits / group saves whose `nextRetryAt` has passed.
    /// On success the entry is removed; on failure it's bumped (retry
    /// count + next retry rescheduled per exponential backoff,
    /// capped at 60s). No max-attempt limit — CloudKit will
    /// eventually come back.
    private func startEmitRetryLoop() {
        guard retryEmitTask == nil else { return }
        retryEmitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.retryTickInterval))
                guard let self else { return }
                await self.drainPendingGroupSaves()
                await self.drainPendingMemberPublishes()
                await self.drainPendingEmits()
            }
        }
    }

    /// Offline-first group creation entry point. CreateGroupViewModel
    /// calls this after building the GroupSession in-process and
    /// updating local state. We try once immediately; on failure the
    /// save goes into the persisted retry queue. The user is already
    /// on the dashboard by then — they never feel the network round-
    /// trip, success or fail.
    func dispatchGroupSave(_ group: GroupSession) {
        Task { [weak self, group] in
            guard let self else { return }
            let succeeded = await self.attemptGroupSave(group)
            if !succeeded {
                self.enqueueGroupSave(group)
            }
        }
    }

    private func attemptGroupSave(_ group: GroupSession) async -> Bool {
        do {
            try await groupService.saveGroup(group)
            return true
        } catch {
            return false
        }
    }

    private func enqueueGroupSave(_ group: GroupSession) {
        // Idempotent on group ID — repeated dispatch of the same group
        // doesn't pile up duplicate entries. If an entry already
        // exists we leave its existing backoff state alone.
        guard !pendingGroupSaves.contains(where: { $0.group.id == group.id }) else {
            return
        }
        let entry = PendingGroupSave(
            group: group,
            retryCount: 0,
            nextRetryAt: Date().addingTimeInterval(PendingGroupSave.backoff(after: 0))
        )
        pendingGroupSaves.append(entry)
    }

    private func drainPendingGroupSaves() async {
        guard !pendingGroupSaves.isEmpty else { return }
        let now = Date()
        let dueIDs = pendingGroupSaves
            .filter { $0.nextRetryAt <= now }
            .map { $0.group.id }

        for groupID in dueIDs {
            guard let idx = pendingGroupSaves.firstIndex(where: { $0.group.id == groupID })
            else { continue }
            let entry = pendingGroupSaves[idx]
            // Prefer the latest local snapshot of the group if we
            // still have one — the user may have triggered other
            // mutations (extension proposal, etc.) since the queue
            // entry was minted. CloudKit can replay the whole record.
            let current = myGroups.first(where: { $0.id == groupID }) ?? entry.group
            let succeeded = await attemptGroupSave(current)
            if succeeded {
                pendingGroupSaves.removeAll { $0.group.id == groupID }
            } else if let stillIdx = pendingGroupSaves.firstIndex(where: { $0.group.id == groupID }) {
                pendingGroupSaves[stillIdx] = entry.bumpedRetry(now: Date())
            }
        }
    }

    /// Offline-first entry point for publishing a freshly-minted
    /// per-group `User` record. Caller (CreateGroup / JoinGroup) has
    /// already added the user to local state; this hands the
    /// cloud-side publish to the retry queue. Try once immediately,
    /// queue on failure.
    func dispatchMemberPublish(_ user: User, in group: GroupSession) {
        Task { [weak self, user, group] in
            guard let self else { return }
            let succeeded = await self.attemptMemberPublish(user: user, in: group)
            if !succeeded {
                self.enqueueMemberPublish(user: user, in: group)
            }
        }
    }

    private func attemptMemberPublish(user: User, in group: GroupSession) async -> Bool {
        do {
            try await groupService.publish(user: user, in: group)
            return true
        } catch {
            return false
        }
    }

    private func enqueueMemberPublish(user: User, in group: GroupSession) {
        // Idempotent on (groupID, userID): a re-dispatch of the same
        // user in the same group leaves the existing backoff state
        // alone. We do refresh the User payload so the most recent
        // identity bits (display name, avatar, ban hash) are what
        // gets shipped when the next retry fires.
        if let idx = pendingMemberPublishes.firstIndex(where: {
            $0.groupID == group.id && $0.user.id == user.id
        }) {
            let entry = pendingMemberPublishes[idx]
            pendingMemberPublishes[idx] = PendingMemberPublish(
                user: user,
                groupID: entry.groupID,
                inviteCode: group.inviteCode,
                retryCount: entry.retryCount,
                nextRetryAt: entry.nextRetryAt
            )
            return
        }
        let entry = PendingMemberPublish(
            user: user,
            groupID: group.id,
            inviteCode: group.inviteCode,
            retryCount: 0,
            nextRetryAt: Date().addingTimeInterval(PendingMemberPublish.backoff(after: 0))
        )
        pendingMemberPublishes.append(entry)
    }

    private func drainPendingMemberPublishes() async {
        guard !pendingMemberPublishes.isEmpty else { return }
        let now = Date()
        let dueKeys = pendingMemberPublishes
            .filter { $0.nextRetryAt <= now }
            .map { ($0.groupID, $0.user.id) }

        for (groupID, userID) in dueKeys {
            guard let idx = pendingMemberPublishes.firstIndex(where: {
                $0.groupID == groupID && $0.user.id == userID
            }) else { continue }
            let entry = pendingMemberPublishes[idx]
            // Reconstruct the group from the most recent local
            // snapshot so the publish carries any locally-pending
            // mutations (e.g. invite-code change is impossible, but
            // banlist / member changes would otherwise be lost on
            // the queued group). Fall back to a minimal stub built
            // from the queue entry if the group is gone locally.
            let group = myGroups.first(where: { $0.id == groupID })
                ?? GroupSession(
                    id: groupID,
                    name: "",
                    inviteCode: entry.inviteCode,
                    ownerID: entry.user.id,
                    expiresAt: .distantFuture
                )
            // Prefer the freshest User snapshot too — heartbeat
            // updates lastSeen / position / cursor on the local
            // copy, and we want those in the publish.
            let user = group.members.first(where: { $0.id == userID }) ?? entry.user
            let succeeded = await attemptMemberPublish(user: user, in: group)
            if succeeded {
                pendingMemberPublishes.removeAll {
                    $0.groupID == groupID && $0.user.id == userID
                }
            } else if let stillIdx = pendingMemberPublishes.firstIndex(where: {
                $0.groupID == groupID && $0.user.id == userID
            }) {
                pendingMemberPublishes[stillIdx] = entry.bumpedRetry(now: Date())
            }
        }
    }

    private func drainPendingEmits() async {
        guard !pendingEmits.isEmpty else { return }
        let now = Date()
        // Snapshot the due entries by ID — pendingEmits is mutated
        // by attemptCloudEmit's downstream effects (delivery status
        // updates, sync re-evaluation), so we iterate over a stable
        // snapshot to avoid index drift.
        let dueIDs = pendingEmits
            .filter { $0.nextRetryAt <= now }
            .map { $0.event.id }

        for eventID in dueIDs {
            guard let idx = pendingEmits.firstIndex(where: { $0.event.id == eventID })
            else { continue }
            let entry = pendingEmits[idx]
            let succeeded = await attemptCloudEmit(entry.event)
            if succeeded {
                pendingEmits.removeAll { $0.event.id == eventID }
            } else if let stillIdx = pendingEmits.firstIndex(where: { $0.event.id == eventID }) {
                pendingEmits[stillIdx] = entry.bumpedRetry(now: Date())
            }
        }
    }

    /// Single ingestion point for every event we receive — local
    /// emit, CloudKit forward sync, CloudKit older-batch fetch, BLE
    /// gossip. Centralizing the append + cursor bookkeeping here
    /// ensures the local log and both cursors stay consistent no
    /// matter how the event arrived.
    private func ingestEvent(_ event: Event) {
        var log = eventsByGroup[event.groupID] ?? []
        // Idempotent on event ID so duplicate gossip / re-syncs are
        // free at this layer — the reducer is also idempotent, so
        // this is just a cheap dedup before further work.
        guard !log.contains(where: { $0.id == event.id }) else { return }
        log.append(event)
        eventsByGroup[event.groupID] = log

        // Update both cursors. `latest` always moves forward to the
        // newest known event. `oldest` moves backward to the oldest
        // known — useful when the very first batch we ingest comes
        // from `loadOlderEvents` (newest-first by service contract).
        let prior = eventCursors[event.groupID]
        if prior == nil || event.cursor > prior! {
            eventCursors[event.groupID] = event.cursor
        }
        let priorOldest = oldestEventCursors[event.groupID]
        if priorOldest == nil || event.cursor < priorOldest! {
            oldestEventCursors[event.groupID] = event.cursor
        }

        applyEventSideEffects(event)
    }

    /// Reason we're tearing down a local group, used by
    /// `tearDownLocalGroup` to decide which notice to surface.
    private enum LocalGroupTeardownReason {
        case banned   // owner kicked us
        case left     // we (or some other device acting as us) left
    }

    /// Drop a group from local state and surface the appropriate
    /// user-facing notice. Idempotent — re-applying after the group
    /// is already gone is a no-op. Used by both the CloudKit refresh
    /// path (`isLocalUserBanned` check) and the offline gossip path
    /// (`memberRemoved` event side effect) so the experience is the
    /// same regardless of which channel delivered the kick.
    private func tearDownLocalGroup(_ groupID: UUID,
                                    reason: LocalGroupTeardownReason) {
        guard let group = myGroups.first(where: { $0.id == groupID }) else {
            return
        }
        let isActive = currentGroup?.id == groupID
        myGroups.removeAll { $0.id == groupID }
        membershipByGroupID.removeValue(forKey: groupID)
        if isActive {
            currentGroup = nil
            switch reason {
            case .banned: bannedFromGroupName = group.name
            case .left:   groupDeletedNotice = group.name
            }
            path.removeAll()
        }
        Task { [notificationService, groupID] in
            await notificationService.cancelAll(for: groupID)
        }
    }

    /// Hook for events whose effect on local state goes beyond the
    /// pure reducer fold. The reducer is `events → GroupSession?` —
    /// when "the group is gone" is the right answer we need a side
    /// effect (drop from `myGroups`, surface a notice, cancel
    /// notifications), not a pure value. Centralized here so the
    /// behavior is the same whether the event arrived via local
    /// emit, CloudKit sync, or BLE gossip.
    private func applyEventSideEffects(_ event: Event) {
        switch event.payload {
        case .chatMessage(let text):
            // Mirror the chat-message event into the in-memory chat
            // buffer so the dashboard badge + any chat list reads see
            // the message regardless of which path delivered it
            // (local emit, transport gossip, or CloudKit replay).
            let groupHash = PeerPresence.groupHash(
                forInviteCode: myGroups.first(where: { $0.id == event.groupID })?
                    .inviteCode ?? ""
            )
            let message = ChatMessage(
                id: event.id,
                groupHash: groupHash,
                senderID: event.authorID,
                text: text,
                timestamp: event.createdAt
            )
            appendChat(message)
        case .memberRemoved(let removedID, _, _):
            // The owner kicked someone. If that someone is us, the
            // event-driven side effect is "tear down local group
            // state and surface a notice" — same outcome that
            // `refreshCurrentGroup` produces when it sees our banHash
            // server-side. Doing it here closes the offline gap: a
            // kick that arrives only via BLE gossip (CloudKit
            // unreachable, or disabled entirely) still kicks us off
            // the dashboard.
            guard let ourMemberID = membershipByGroupID[event.groupID],
                  removedID == ourMemberID else { return }
            tearDownLocalGroup(event.groupID, reason: .banned)
        case .memberLeft(let leftID):
            // Mirror of memberRemoved but without the ban — only
            // matters in the (rare) case where some other device
            // initiated leave on our behalf. Tear down so we don't
            // keep a ghost membership locally.
            guard let ourMemberID = membershipByGroupID[event.groupID],
                  leftID == ourMemberID else { return }
            tearDownLocalGroup(event.groupID, reason: .left)
        case .groupDeleted:
            // The author tore down explicitly in `remove(group:)`.
            // Everyone else: drop the group locally and surface a
            // notice so the user understands why the dashboard
            // disappeared. Match by author against both currentUser
            // (active group) and the per-group membership ID (any
            // group in myGroups) so we don't double-tear-down.
            let authorIsLocal = event.authorID == currentUser.id
                || event.authorID == membershipByGroupID[event.groupID]
            guard !authorIsLocal else { return }
            guard let group = myGroups.first(where: { $0.id == event.groupID }) else {
                return
            }
            let isActive = currentGroup?.id == event.groupID
            myGroups.removeAll { $0.id == event.groupID }
            membershipByGroupID.removeValue(forKey: event.groupID)
            if isActive {
                currentGroup = nil
                groupDeletedNotice = group.name
                path.removeAll()
            }
            Task { [notificationService, groupID = event.groupID] in
                await notificationService.cancelAll(for: groupID)
            }
        default:
            break
        }
    }

    /// Broadcast an event over the payload transport if at least one
    /// in-range peer's cursor is older than the event. Skips the send
    /// if every tracked peer is already caught up.
    ///
    /// **First-sync flooding caveat:** when we receive a large batch
    /// from CloudKit (e.g. after a cold launch sync), each event runs
    /// through this filter so we don't re-broadcast events nearby
    /// peers already have.
    private func broadcastEventIfPeersBehind(_ event: Event) {
        guard !peerCursors.isEmpty else { return }
        let anyBehind = peerCursors.values.contains { peerCursor in
            event.cursor > peerCursor
        }
        guard anyBehind else { return }
        sendEventToPayloadTransport(event)
    }

    /// Unconditional transport broadcast for events the local user
    /// just authored. Skipping the `peerCursors`-empty gate matters
    /// when a new peer just joined and their cursor hasn't arrived
    /// yet. Idempotent at the receiver because the reducer dedups on
    /// event ID, so duplicate-arrival is harmless.
    private func broadcastLocalEmit(_ event: Event) {
        sendEventToPayloadTransport(event)
    }

    /// Wrap `event` in a `PayloadFrame.event` and broadcast over the
    /// transport. Full event flows (no `strippedForBLE()` shrinkage)
    /// because MPC / Wi-Fi Aware can carry the avatar payload.
    private func sendEventToPayloadTransport(_ event: Event) {
        guard let data = PayloadFrame.event(event).encoded() else { return }
        payloadTransport.broadcast(data)
    }

    /// Paginated scroll-to-top history fetch. Called by the timeline
    /// UI when the user scrolls past the oldest message on screen.
    /// Pulls one page (`Self.timelinePageSize`) of events older than
    /// our current oldest-local-cursor, ingests them locally, and
    /// updates the cursor. If the batch comes back smaller than a
    /// full page we've hit the start of the group's history and
    /// record it so the UI can stop firing more requests.
    func loadOlderEvents(for groupID: UUID) async {
        // Already at the start — nothing more to load.
        guard !groupsAtStartOfHistory.contains(groupID) else { return }

        let cursor = oldestEventCursors[groupID]
        let batch: [Event]
        do {
            batch = try await groupService.fetchEvents(
                forGroupID: groupID,
                olderThan: cursor,
                limit: Self.timelinePageSize
            )
        } catch {
            return
        }

        for event in batch {
            ingestEvent(event)
        }

        // Less than a full page = start of history. Latch that so the
        // UI doesn't keep re-asking on every scroll.
        if batch.count < Self.timelinePageSize {
            groupsAtStartOfHistory.insert(groupID)
        }
    }

    /// Push every locally-known event newer than `cursor` for `groupID`
    /// onto the BLE wire, in chronological order. Used by the cursor-
    /// mismatch path: when a peer's presence arrives with an older
    /// cursor, we shove the missing slice at them.
    private func pushEventsNewer(than cursor: EventCursor, in groupID: UUID) async {
        let events: [Event]
        do {
            events = try await groupService.fetchEvents(
                forGroupID: groupID, since: cursor
            )
        } catch {
            return
        }
        let sorted = events.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for event in sorted {
            sendEventToPayloadTransport(event)
        }
    }

    /// Pull all events newer than our cursor for `groupID`, fold them
    /// into the active state, advance the cursor. Called on push,
    /// on pull-to-refresh, and on cold launch via `replayEventsOnLaunch`.
    /// Safe to call concurrently — idempotent at the reducer level.
    private func syncEvents(for groupID: UUID) async {
        let cursor = eventCursors[groupID]
        let fetched: [Event]
        do {
            fetched = try await groupService.fetchEvents(
                forGroupID: groupID, since: cursor
            )
        } catch {
            // Silent — the next push or pull-to-refresh will retry.
            return
        }
        guard !fetched.isEmpty else { return }

        // Apply on top of whichever local snapshot is freshest. For
        // the active group we use `currentGroup` so the UI updates in
        // the same turn; for background groups we fold into the
        // `myGroups` entry.
        applyEvents(fetched, to: groupID)

        // Advance the cursor to the newest event we just applied. Sort
        // first because CloudKit's order isn't guaranteed under cursor
        // pagination.
        if let newest = fetched.max(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }) {
            eventCursors[groupID] = newest.cursor
        }

        // Cursor-gated re-broadcast of every event we just learned
        // from CloudKit. This closes the gossip loop: a peer in BLE
        // range but offline from CloudKit hears about events through
        // us. The cursor check inside `broadcastEventIfPeersBehind`
        // is what prevents first-sync flooding — if every nearby peer
        // already has the event (their cursors are ahead of it), the
        // broadcast is skipped.
        for event in fetched {
            broadcastEventIfPeersBehind(event)
        }

        // CloudKit fetch can include refreshed member User records,
        // whose updated cursors might unlock delivery promotions for
        // our outgoing events. Re-evaluate once at the end of the
        // sync rather than per-event for batched efficiency.
        reevaluateDeliveryStatus(for: groupID)

        // Opportunistic retry: a successful sync means CloudKit is
        // reachable. Bump every pending emit / group save's
        // nextRetryAt to "now" so the next tick drains them
        // immediately instead of waiting out the full exponential
        // backoff. Saves the user 30-60s of waiting after a network
        // blip resolves.
        if !pendingEmits.isEmpty {
            let now = Date()
            pendingEmits = pendingEmits.map { entry in
                PendingEmit(
                    event: entry.event,
                    retryCount: entry.retryCount,
                    nextRetryAt: min(entry.nextRetryAt, now)
                )
            }
        }
        if !pendingGroupSaves.isEmpty {
            let now = Date()
            pendingGroupSaves = pendingGroupSaves.map { entry in
                PendingGroupSave(
                    group: entry.group,
                    retryCount: entry.retryCount,
                    nextRetryAt: min(entry.nextRetryAt, now)
                )
            }
        }
    }

    /// Apply a batch of events to either `currentGroup` (if it matches
    /// the targeted group ID) or the corresponding entry in `myGroups`.
    /// Members and banlist updates flow through the existing newest-
    /// wins merge so live position data on the User records doesn't
    /// get clobbered by the event-derived snapshot.
    private func applyEvents(_ events: [Event], to groupID: UUID) {
        // Funnel every event through the central ingestion path so
        // the local log and cursors stay in sync. Idempotent — no
        // harm if some of these already landed via gossip first.
        for event in events {
            ingestEvent(event)
        }

        let target = currentGroup?.id == groupID
            ? currentGroup
            : myGroups.first(where: { $0.id == groupID })
        guard let baseline = target else { return }

        guard let folded = EventReducer.reduce(events, into: baseline) else {
            return
        }

        // Merge: the reducer-derived snapshot carries authoritative
        // membership + banlist + expiry, but local member records hold
        // the freshest position/heading data. Patch the folded members
        // with whichever copy has a newer `lastSeen`.
        var merged = folded
        for i in merged.members.indices {
            let foldedMember = merged.members[i]
            if let local = baseline.members.first(where: { $0.id == foldedMember.id }),
               local.lastSeen > foldedMember.lastSeen {
                merged.members[i] = local
            }
        }
        // Carry the local invite code through — events don't always
        // re-state it, but the existing snapshot does.
        if merged.inviteCode.isEmpty {
            merged.inviteCode = baseline.inviteCode
        }

        addOrUpdate(group: merged)
        if currentGroup?.id == groupID {
            currentGroup = merged
        }
    }

    private func refreshCurrentGroup() async {
        guard let active = currentGroup else { return }
        do {
            guard var updated = try await groupService.fetchGroup(groupID: active.id) else {
                // Two interpretations of `nil`:
                //   1. The backend has authoritative server state and
                //      truly says "this group is gone" — drop it locally
                //      and tell the user.
                //   2. The backend is local-only (LocalGroupService) and
                //      simply doesn't know about this group because we
                //      joined it via BLE, not by creating it locally.
                //      In that case `nil` is meaningless and we MUST
                //      NOT tear down — the only source of truth for the
                //      group's existence is our own local state.
                // `supportsRemoteJoin` distinguishes the two.
                if groupService.supportsRemoteJoin {
                    let groupName = active.name
                    remove(group: active)
                    groupDeletedNotice = groupName
                }
                return
            }
            // Detect post-removal: if the owner kicked us, our banHash
            // is now in the banlist on the server. Tear down local
            // group state and surface the alert via the dashboard
            // modifier so the user understands why they're back home.
            if isLocalUserBanned(from: updated) {
                let groupName = updated.name
                remove(group: updated)
                bannedFromGroupName = groupName
                return
            }
            // Banlist filter: CloudKit's `fetchMembers` returns every
            // record that points at this group, including freshly-
            // kicked members whose User CKRecord delete hasn't yet
            // propagated. The Group record's `bannedMembers` is the
            // authoritative list of who's been kicked — drop anyone
            // whose `banHash` appears there so the dashboard doesn't
            // briefly resurface a banned member after each refresh.
            let bannedHashes = Set(updated.bannedMembers.map(\.banHash))
            updated.members.removeAll { member in
                guard let hash = member.banHash else { return false }
                return bannedHashes.contains(hash)
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
            // Self entry: prefer the live `currentUser` if it's newer
            // than either cloud or the active cached copy. If the cloud
            // query missed us entirely (indexing delay right after
            // join), append our own record so we don't vanish from
            // our own group view on the post-join refresh tick.
            if let myID = membershipByGroupID[updated.id] {
                if let myIdx = updated.members.firstIndex(where: { $0.id == myID }) {
                    if currentUser.lastSeen >= updated.members[myIdx].lastSeen {
                        updated.members[myIdx] = currentUser
                    }
                } else {
                    updated.members.append(currentUser)
                }
            }

            // Indexing-delay safety net: re-add any local members the
            // cloud query missed, UNLESS they've been banned (signal
            // they're intentionally removed). CloudKit's public-DB
            // index updates a few seconds behind writes, so a refresh
            // fired by a silent push can return stale results. Without
            // this merge, every member would briefly disappear from
            // every other member's screen the moment a new join arrives.
            // The merge is conservative — only members with a recent
            // `lastSeen` survive (60s), so genuinely-removed members
            // (record deleted server-side) aren't resurrected forever.
            // `bannedHashes` is already in scope from the cloud-side
            // member filter above — reuse it here for the same
            // banlist-respecting purpose on the local-only merge.
            let cloudIDs = Set(updated.members.map(\.id))
            let staleCutoff = Date().addingTimeInterval(-60)
            for localMember in active.members where !cloudIDs.contains(localMember.id) {
                if let hash = localMember.banHash, bannedHashes.contains(hash) {
                    continue
                }
                guard localMember.lastSeen > staleCutoff else { continue }
                updated.members.append(localMember)
            }

            currentGroup = updated
            addOrUpdate(group: updated)
            // Member records came back from CloudKit with possibly
            // updated event cursors — check whether any of our
            // outgoing events can now be marked delivered.
            reevaluateDeliveryStatus(for: updated.id)
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
    ///
    /// Offline-first: local `pendingExtension` is set immediately and
    /// the event is emitted (queued via `pendingEmits` if CloudKit is
    /// unreachable). The cloud snapshot save also routes through
    /// `dispatchGroupSave` so the CKRecord catches up whenever
    /// connectivity returns. Other members reduce the
    /// `extensionProposed` event into their own state when it
    /// reaches them via BLE gossip or cloud sync.
    func proposeCurrentExtension(newExpiresAt: Date) async throws {
        guard let group = currentGroup else { return }

        var updated = group
        updated.pendingExtension = PendingExtension(
            newExpiresAt: newExpiresAt,
            proposedAt: .now,
            acceptedMemberIDs: []
        )
        addOrUpdate(group: updated)
        currentGroup = updated

        emit(.extensionProposed(newExpiresAt: newExpiresAt), in: group.id)
        dispatchGroupSave(updated)

        // Best-effort direct call — dispatchGroupSave is the durable
        // fallback so we ignore failures here.
        Task { [groupService, groupID = group.id, newExpiresAt] in
            _ = try? await groupService.proposeExtension(
                groupID: groupID, newExpiresAt: newExpiresAt
            )
        }
    }

    /// Member accepts the active extension proposal on `currentGroup`.
    ///
    /// Offline-first: local `pendingExtension.acceptedMemberIDs` is
    /// appended immediately and the event is emitted. Cloud snapshot
    /// catch-up happens via `dispatchGroupSave`. Other members reduce
    /// the `extensionAccepted` event when it reaches them.
    func acceptCurrentExtension() async throws {
        guard let group = currentGroup,
              let memberID = membershipByGroupID[group.id] else { return }

        var updated = group
        if var pending = updated.pendingExtension {
            if !pending.acceptedMemberIDs.contains(memberID) {
                pending.acceptedMemberIDs.append(memberID)
            }
            updated.pendingExtension = pending
        }
        addOrUpdate(group: updated)
        currentGroup = updated

        emit(.extensionAccepted(memberID: memberID), in: group.id)
        dispatchGroupSave(updated)

        Task { [groupService, groupID = group.id, memberID] in
            _ = try? await groupService.acceptExtension(
                groupID: groupID, memberID: memberID
            )
        }
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
                    // Mark the expiry resolution in the event log so
                    // peers that weren't in the accepted-extension list
                    // can reconcile when they next sync. The new expiry
                    // becomes the canonical one moving forward.
                    if group.ownerID == currentUser.id {
                        emit(.extensionResolved(newExpiresAt: resolved.expiresAt),
                             in: group.id)
                    }
                    if currentGroup?.id == group.id {
                        currentGroup = resolved
                        if let myID = membershipByGroupID[group.id],
                           let me = resolved.members.first(where: { $0.id == myID }) {
                            currentUser = me
                        } else {
                            // I didn't accept the extension by the
                            // deadline — server-side cleanup excluded
                            // me from the resolved group. Drop the
                            // group locally and pop back to home.
                            // `remove(group:)` will idempotently
                            // re-issue the server-side delete on our
                            // member record (no-op if already gone).
                            remove(group: resolved)
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

    private func persistEventCursors() {
        if let data = try? JSONEncoder().encode(eventCursors) {
            defaults.set(data, forKey: Self.eventCursorsKey)
        }
    }

    private static func loadEventCursors(defaults: UserDefaults) -> [UUID: EventCursor] {
        guard let data = defaults.data(forKey: eventCursorsKey),
              let decoded = try? JSONDecoder().decode([UUID: EventCursor].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistOldestEventCursors() {
        if let data = try? JSONEncoder().encode(oldestEventCursors) {
            defaults.set(data, forKey: Self.oldestEventCursorsKey)
        }
    }

    private static func loadOldestEventCursors(defaults: UserDefaults) -> [UUID: EventCursor] {
        guard let data = defaults.data(forKey: oldestEventCursorsKey),
              let decoded = try? JSONDecoder().decode([UUID: EventCursor].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistEventsByGroup() {
        // Strip avatar payloads from `memberJoined` events before
        // persisting. Avatars live on the per-group `User` record
        // already; carrying them inside the event log too means each
        // 50-100 KB avatar gets written N times (once per join event
        // per group), trivially exceeding UserDefaults' 4 MB platform
        // ceiling and crashing the app with `CFPrefsPlistSource`
        // truncation. The reducer can reconstruct member avatars from
        // the User record on replay; events don't need them.
        let stripped = eventsByGroup.mapValues { events in
            events.map { $0.strippedForBLE() }
        }
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: Self.eventsByGroupKey)
        }
    }

    private static func loadEventsByGroup(defaults: UserDefaults) -> [UUID: [Event]] {
        guard let data = defaults.data(forKey: eventsByGroupKey),
              let decoded = try? JSONDecoder().decode([UUID: [Event]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistEventDelivery() {
        if let data = try? JSONEncoder().encode(eventDeliveryByID) {
            defaults.set(data, forKey: Self.eventDeliveryKey)
        }
    }

    private static func loadEventDelivery(defaults: UserDefaults) -> [UUID: EventDeliveryStatus] {
        guard let data = defaults.data(forKey: eventDeliveryKey),
              let decoded = try? JSONDecoder().decode([UUID: EventDeliveryStatus].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistPendingEmits() {
        if let data = try? JSONEncoder().encode(pendingEmits) {
            defaults.set(data, forKey: Self.pendingEmitsKey)
        }
    }

    private static func loadPendingEmits(defaults: UserDefaults) -> [PendingEmit] {
        guard let data = defaults.data(forKey: pendingEmitsKey),
              let decoded = try? JSONDecoder().decode([PendingEmit].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistPendingGroupSaves() {
        if let data = try? JSONEncoder().encode(pendingGroupSaves) {
            defaults.set(data, forKey: Self.pendingGroupSavesKey)
        }
    }

    private static func loadPendingGroupSaves(defaults: UserDefaults) -> [PendingGroupSave] {
        guard let data = defaults.data(forKey: pendingGroupSavesKey),
              let decoded = try? JSONDecoder().decode([PendingGroupSave].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistPendingMemberPublishes() {
        if let data = try? JSONEncoder().encode(pendingMemberPublishes) {
            defaults.set(data, forKey: Self.pendingMemberPublishesKey)
        }
    }

    private static func loadPendingMemberPublishes(defaults: UserDefaults) -> [PendingMemberPublish] {
        guard let data = defaults.data(forKey: pendingMemberPublishesKey),
              let decoded = try? JSONDecoder().decode([PendingMemberPublish].self, from: data)
        else { return [] }
        return decoded
    }

    /// Public count exposed to the Home banner so it can show
    /// "X pending uploads" when something hasn't reached CloudKit
    /// yet. Sums both queues — events authored offline AND groups
    /// created offline both count as user-visible pending work.
    var pendingUploadCount: Int {
        pendingEmits.count + pendingGroupSaves.count + pendingMemberPublishes.count
    }

    #if DEBUG
    /// One-shot snapshot of every diagnostic the debug overlay
    /// renders. Computed in one place so the overlay UI is just a
    /// pretty-printer and additions land here, not in the view.
    /// `#if DEBUG`-gated so production binaries don't carry the
    /// surface.
    var debugSnapshot: DebugSnapshot {
        let activeID = currentGroup?.id
        let recent: [Event]
        if let activeID, let log = eventsByGroup[activeID] {
            recent = Array(
                log.sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id.uuidString > $1.id.uuidString
                }
                .prefix(15)
            )
        } else {
            recent = []
        }
        let peerEntries: [DebugSnapshot.PeerCursorEntry] = peerCursors.map { (peerID, cursor) in
            let name = currentGroup?.members.first(where: { $0.id == peerID })?.displayName
                ?? String(peerID.uuidString.prefix(8))
            let mine = activeID.flatMap { eventCursors[$0] }
            let behindBy: Int? = {
                guard let activeID, let log = eventsByGroup[activeID] else { return nil }
                return log.filter { $0.cursor > cursor }.count
            }()
            return DebugSnapshot.PeerCursorEntry(
                memberID: peerID,
                displayName: name,
                cursor: cursor,
                myCursor: mine,
                behindByEvents: behindBy
            )
        }
        return DebugSnapshot(
            localIdentity: localCloudUserID,
            isOnline: isOnline,
            iCloudStatus: iCloudAccountStatus,
            pendingEmitsCount: pendingEmits.count,
            pendingMemberPublishesCount: pendingMemberPublishes.count,
            pendingGroupSavesCount: pendingGroupSaves.count,
            oldestPendingEmitAt: pendingEmits.map { $0.event.createdAt }.min(),
            bleDiagnostics: bleDiagnostics,
            activeGroupID: activeID,
            activeGroupName: currentGroup?.name,
            activeGroupMemberCount: currentGroup?.members.count ?? 0,
            activeGroupEventCount: activeID.flatMap { eventsByGroup[$0]?.count } ?? 0,
            myCursor: activeID.flatMap { eventCursors[$0] },
            peerCursors: peerEntries.sorted { ($0.displayName ?? "") < ($1.displayName ?? "") },
            recentEvents: recent
        )
    }
    #endif

    /// Public accessor for the timeline UI. Returns nil for events
    /// authored by other members (we don't render dots on their
    /// bubbles) and for events that predate the delivery-tracking
    /// feature (no recorded status, no dot).
    func deliveryStatus(for event: Event) -> EventDeliveryStatus? {
        // Only show status on events we authored — others' status is
        // not ours to display.
        let myID = membershipByGroupID[event.groupID] ?? currentUser.id
        guard event.authorID == myID else { return nil }
        return eventDeliveryByID[event.id]
    }

    /// Monotonic advance — refuses to downgrade a status. Used by all
    /// the transition paths (emit → pending, cloud-append → cloud,
    /// all-peers-caught-up → delivered).
    private func advanceDelivery(_ eventID: UUID,
                                 to status: EventDeliveryStatus) {
        let current = eventDeliveryByID[eventID]
        if let current, status.rank <= current.rank { return }
        eventDeliveryByID[eventID] = status
    }

    /// Walk every event we authored in this group; for any whose
    /// status is below `.delivered`, promote to `.delivered` if every
    /// *other* member's published cursor is at or past it. Members
    /// without a cursor are treated as "not yet acknowledged" so a
    /// group with even one offline member keeps showing ✓ instead
    /// of ✓✓ — which is what users expect from chat-app delivery
    /// indicators.
    ///
    /// Solo groups (only the local member) skip the upgrade entirely:
    /// there's no one to deliver to, so the status caps at `.cloud`.
    private func reevaluateDeliveryStatus(for groupID: UUID) {
        guard let group = currentGroup?.id == groupID
              ? currentGroup
              : myGroups.first(where: { $0.id == groupID }) else {
            return
        }

        let myID = membershipByGroupID[groupID]
        let otherMembers = group.members.filter { $0.id != myID }
        guard !otherMembers.isEmpty else { return }

        let log = eventsByGroup[groupID] ?? []
        for event in log where event.authorID == myID {
            let status = eventDeliveryByID[event.id] ?? .pending
            guard status.rank < EventDeliveryStatus.delivered.rank else { continue }

            // All other members must have a cursor at or past this
            // event's cursor. Members with no cursor data → bail out
            // for this event; we can't confirm delivery to them.
            let allAcknowledged = otherMembers.allSatisfy { member in
                guard let cursor = member.eventCursor else { return false }
                // "cursor >= event.cursor" is equivalent to
                // "not (event.cursor > cursor)" — the EventCursor
                // ordering already provides strict-greater-than.
                return !(event.cursor > cursor)
            }
            if allAcknowledged {
                advanceDelivery(event.id, to: .delivered)
            }
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

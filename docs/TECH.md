# GroupIn — Technical Documentation

This document captures the architecture, design decisions, and roadmap for
GroupIn as of the current build. Status tags follow each section heading:

- **[shipped]** — implemented and working in the current codebase
- **[planned]** — designed and committed to but not yet built
- **[exploratory]** — discussed but no commitment yet

---

## 1. Product Overview

GroupIn is an iOS app for short-lived, activity-scoped group awareness. A user
creates a temporary group around an activity (festival, trip, tour, walk,
hike), invites others with a short code, and everyone in that group sees each
other live on a single map until the group's owner-defined expiry hits, at
which point the group hard-deletes.

Lead use cases:

- **Festival & Concert** — crowds, weak cell signal, short window
- **Trip** — multi-day travel, possibly across borders, often with intermittent connectivity
- **Tour** — guided activity, museum, structured group
- **City Exploring** — wandering a city, splitting up, regrouping
- **Nature** — hiking, camping, areas with unreliable reception
- **Other** — fallback bucket

The app is iOS-only by deliberate scope.

---

## 2. Architecture [shipped]

### 2.1 Layers

```
┌──────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                          │
│  - RootView, OnboardingView, HomeView                     │
│  - CreateGroupView, JoinGroupView, GroupDashboardView     │
│  - ProfileEditorView, AvatarCropperView                   │
│  - ExtendGroupSheet                                       │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│  ViewModels (@Observable, @MainActor)                     │
│  - HomeViewModel (placeholder)                            │
│  - CreateGroupViewModel, JoinGroupViewModel               │
│  - GroupDashboardViewModel                                │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│  AppState (@Observable, @MainActor, env-injected)         │
│  Owns: localProfile, currentUser, currentGroup, myGroups, │
│        membershipByGroupID, path, locationAuthStatus      │
│  Wraps: groupService, locationService, notificationService│
└──┬─────────┬──────────┬─────────────────────────────────┘
   │         │          │
┌──┴──┐   ┌──┴──────┐ ┌─┴───────────────┐
│Group│   │Location │ │Notification     │
│Svc  │   │Svc      │ │Svc              │
└─────┘   └─────────┘ └─────────────────┘
   │
   ├── LocalGroupService (in-memory + UserDefaults)
   └── CloudKitService (CloudKit public DB)
```

### 2.2 Stack

- **Swift 6** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Approachable
  Concurrency mode). All UI types inherit MainActor isolation by default.
- **SwiftUI** with `@Observable` macro (iOS 17+ Observation framework). No
  `ObservableObject` / `@Published` anywhere.
- **NavigationStack** driven by `AppState.path: [AppRoute]`. Navigation is
  programmatic and testable.
- **MVVM** — views own no logic beyond layout. ViewModels are `@MainActor
  @Observable final class`, owned by views via `@State`, constructed in
  `RootView` at navigation time.
- **Service protocols** — every external dependency (group sync, location,
  notifications) is behind a protocol. Concrete implementations are injected
  into `AppState`. Tests and previews use mocks; the app entry point picks
  CloudKit or local.

### 2.3 Module structure

```
GroupIn/
├── GroupInApp.swift          # entry point, picks groupService
├── App/
│   └── AppState.swift        # global state, env-injected
├── Models/
│   ├── User.swift            # per-group membership + Coordinate
│   ├── GroupSession.swift    # group + PendingExtension
│   ├── GroupCategory.swift   # activity-typed enum + tints/icons
│   └── LocalProfile.swift    # device-side profile
├── Services/
│   ├── CloudKitServicing.swift     # protocol contract
│   ├── LocalGroupService.swift     # in-memory implementation
│   ├── CloudKitService.swift       # CloudKit-backed implementation
│   ├── CloudKitRecordMapping.swift # GroupSession/User <-> CKRecord
│   ├── LocationService.swift       # Core Location + AsyncStream
│   └── NotificationService.swift   # UNUserNotifications wrapper
├── ViewModels/
│   ├── HomeViewModel.swift
│   ├── CreateGroupViewModel.swift
│   ├── JoinGroupViewModel.swift
│   └── GroupDashboardViewModel.swift
└── Views/
    ├── RootView.swift
    ├── Common/
    │   ├── AvatarView.swift           # photo or colored initial
    │   ├── AvatarCropperView.swift    # circular crop UI
    │   ├── PresenceStatus.swift       # live/recent/stale/offline
    │   └── MemberColors.swift         # deterministic per-UUID palette
    ├── Onboarding/OnboardingView.swift
    ├── Profile/ProfileEditorView.swift
    ├── Home/HomeView.swift
    └── Group/
        ├── CreateGroupView.swift
        ├── JoinGroupView.swift
        ├── GroupDashboardView.swift
        └── ExtendGroupSheet.swift
```

---

## 3. Data Model [shipped]

### 3.1 LocalProfile

Device-only. Holds the user's display name and optional avatar bytes
(JPEG, ~30 KB after compression).

```swift
struct LocalProfile: Codable, Equatable {
    var displayName: String
    var avatarData: Data?
    var needsOnboarding: Bool { ... }
}
```

`needsOnboarding` is true while `displayName` is blank or the legacy "User"
placeholder. `RootView` gates the entire app on this until the user picks
a name.

### 3.2 User (per-group membership)

```swift
struct User: Identifiable, Hashable, Codable {
    let id: UUID                  // fresh per group join/create
    var displayName: String
    var avatarData: Data?
    var lastSeen: Date
    var coordinate: Coordinate?
}
```

The `id` is **per-membership**, not per-device. See section 4.

### 3.3 GroupSession

```swift
struct GroupSession: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var inviteCode: String        // 6 chars from a confusion-free alphabet
    var category: GroupCategory
    var createdAt: Date
    var members: [User]
    let ownerID: UUID
    var expiresAt: Date
    var pendingExtension: PendingExtension?
}
```

A custom `init(from:)` decoder defaults missing `category` to `.other` so
old persisted groups migrate gracefully.

### 3.4 GroupCategory

Activity-typed, not relationship-typed. Six cases:

| Case | Label | Icon | Tint | Default duration |
|------|-------|------|------|-------------------|
| `.festival`  | Festival & Concert | `music.note.list`     | pink  | 12 hours |
| `.trip`      | Trip               | `airplane`            | blue  | 1 day    |
| `.tour`      | Tour               | `map.fill`            | brown | 4 hours  |
| `.exploring` | City Exploring     | `building.2.fill`     | teal  | 4 hours  |
| `.nature`    | Nature             | `tree.fill`           | green | 12 hours |
| `.other`     | Other              | `ellipsis.circle.fill`| gray  | 4 hours  |

Each category also exposes a `subtitle` for the picker. The default duration
seeds the create flow but is fully overridable.

### 3.5 PendingExtension

```swift
struct PendingExtension: Codable, Hashable {
    var newExpiresAt: Date
    var proposedAt: Date
    var acceptedMemberIDs: [UUID]
}
```

When the owner extends a group, this struct is set. At the original
`expiresAt`, the expiry monitor filters members down to owner + accepters,
advances `expiresAt` to `newExpiresAt`, and clears the pending struct.

### 3.6 Coordinate

```swift
struct Coordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double
    var clLocation: CLLocationCoordinate2D { ... }
}
```

A plain value type — `CLLocationCoordinate2D` isn't `Codable` itself, so we
wrap it.

---

## 4. Identity — Anonymous per Group [shipped]

The identity model is a deliberate privacy choice.

- `LocalProfile` (name + avatar) lives on this device only. It's not synced.
- When the user creates or joins a group, `AppState.makeMembership()` mints
  a **fresh UUID** for that membership and seeds the new `User` with the
  current profile's name and avatar.
- `AppState.membershipByGroupID: [UUID: UUID]` records "in group X my member
  ID is Y." This map is local-only and persisted to UserDefaults as
  `[String: String]` (since `UUID` keys aren't JSON-friendly).
- Two memberships in two different groups have unrelated UUIDs. There is no
  data-level link between "Kian at the festival" and "Kian on the family
  trip."
- Editing the profile (name or avatar) propagates the new values into every
  existing membership via `propagateProfileToMemberships()`, but UUIDs stay
  stable per group.

This means: anyone snooping at the database (or the BLE air, or CloudKit
records) can't correlate one user across multiple groups they're in.

---

## 5. Group Lifecycle [shipped]

### 5.1 Creation

`CreateGroupViewModel.createGroup()`:

1. Trims the name; rejects empty.
2. Mints a fresh membership via `appState.makeMembership()`.
3. Calls `service.createGroup(named:ownerID:expiresAt:)`. The service
   generates a 6-char invite code from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
   (no `0/O`, `1/I`).
4. Calls `service.publish(user:in:)` to write the creator's Member record.
5. Locally appends the creator to `members`, registers the membership in the
   map, sets `currentUser`, sets `currentGroup`, pushes the dashboard route.
6. Detached Task: `appState.registerNotifications(for:)` — requests
   notification permission on first use, schedules the T-30 expiry reminder.

### 5.2 Joining

`JoinGroupViewModel.joinGroup()`:

1. Trims and uppercases the invite code.
2. Calls `service.joinGroup(inviteCode:)` — the service queries by code,
   returns the group with its existing members.
3. Mints a fresh membership for *this* device, calls `publish`, registers
   the mapping, sets state, navigates.

Note that the membership UUID is new; this device cannot impersonate a prior
member.

### 5.3 Expiry & extension consent

The expiry policy is owner-set with re-consent on extension:

- Owner picks a duration at create time (1h / 4h / 12h / 1day or custom).
- A long-lived monitor task (`AppState.startExpiryMonitor`) wakes every 30
  seconds, scans `myGroups` for entries past `expiresAt`, and calls
  `service.resolveExpiry(groupID:)` for each.
- `resolveExpiry` returns:
  - **`nil`** if no `pendingExtension` was set → the group is hard-deleted
    server-side. Locally we call `remove(group:)`.
  - **The updated group** if a pending extension exists → service filters
    members to owner + accepters, advances `expiresAt`, clears the pending
    struct. Locally we mirror the result; if our membership was removed
    (we didn't accept), we call `leaveGroup()`, which pops the dashboard.
- T-30 reminder: scheduled at create + reschedule on extension (because the
  *new* T-30 anchor changes after a successful extension). The reminder
  fires only for the owner.
- If the owner explicitly extends via `ExtendGroupSheet`, the proposal is
  written to CloudKit (or the local dict) and members get a banner on their
  next dashboard refresh. They tap **Accept** to be in the
  `acceptedMemberIDs` array.

### 5.4 Member removal

Three paths:

- User taps **Leave** on the dashboard → `appState.leaveGroup()` clears
  `currentGroup` and pops the path. The group remains in `myGroups` and on
  CloudKit; the user can rejoin later with the same code.
- User swipes a row in HomeView's group list → `appState.remove(group:)`
  drops it from `myGroups`, removes the membership map entry, clears
  `currentGroup` if active, and asks the notification service to cancel
  scheduled reminders for that group.
- Expiry monitor concludes the group should hard-delete →
  `remove(group:)` invoked.

CloudKit-side: explicit "delete from cloud" on user-side leave is **not yet
implemented**. The cloud record persists until expiry. Acceptable for v1.

---

## 6. Location & Presence [shipped]

### 6.1 Core Location configuration

`LocationService`:

- `CLLocationManager` with `desiredAccuracy = kCLLocationAccuracyBest` and
  `distanceFilter = kCLDistanceFilterNone`. Every meaningful fix is
  delivered.
- Permission: when-in-use only.
- Battery: best accuracy continuously is heavy; expect ~50% drain over a
  12-hour event with the dashboard kept open. An adaptive throttle
  (Best when the user explicitly searches for someone, HundredMeters
  otherwise) is on the **[planned]** list.

### 6.2 Streams

The service exposes two `AsyncStream`s consumed by AppState:

- `locationUpdates: AsyncStream<Coordinate>` — fixes
- `authorizationUpdates: AsyncStream<CLAuthorizationStatus>` — permission
  state changes

Both are single-consumer; AppState owns the only iterators.
Delegate methods are `nonisolated` and yield directly to the continuations
(which are `Sendable`).

### 6.3 Publishing

`AppState.startLocationTracking()` spawns a long-lived task that consumes
`locationUpdates`, updates `currentUser.coordinate` and `lastSeen`, mirrors
the change into `currentGroup.members[me]`, and (if online) calls
`groupService.publish` with **a 10-second throttle**. Stationary phones
still publish heartbeats every ~10 seconds so other members' presence
indicators don't flip to "Offline."

### 6.4 Presence states

`PresenceStatus` (in `Views/Common/PresenceStatus.swift`) maps a member's
`lastSeen` and `coordinate` presence to one of four states:

| State    | Threshold       | Color     | Map opacity |
|----------|-----------------|-----------|-------------|
| `.live`  | < 30 s          | green     | 1.0         |
| `.recent`| < 5 min         | blue      | 1.0         |
| `.stale` | < 30 min        | orange    | 0.55        |
| `.offline`| ≥ 30 min or no fix | secondary | 0.3      |

`PresenceBadge` renders the pill; `memberMapPin` applies opacity to the map
marker. The dashboard re-evaluates every 15 seconds via `TimelineView`.

### 6.5 Map UI

- `Map(position: $cameraPosition)` with `Annotation` per member that has a
  coordinate. Markers show `AvatarView` tinted with that member's color.
- Per-member color: `Color.memberColor(for: UUID)` maps the membership UUID
  byte-sum into a 12-color palette. Same UUID → same color across devices,
  reboots, and reinstalls.
- "Fit all members" button (bottom-right of the map) recomputes a region
  containing every member with a coord, with 1.6× padding.
- Auto-fit fires once per dashboard session, the first moment any member
  has a coordinate, via `viewModel.fitInitialIfNeeded()`. After that the
  camera is left alone unless the user explicitly fits or focuses.
- Tapping a member row in the list calls `viewModel.focus(on:)`, which
  zooms tightly on that member and sets `focusedMemberID`. The map pin for
  that member draws a tinted ring + halo for ~4 seconds.

---

## 7. Sync & Persistence [shipped]

Two backends behind the same `CloudKitServicing` protocol. The app entry
point picks one via the `useCloudKit` flag in `GroupInApp.swift`.

### 7.1 LocalGroupService

In-memory `[String: GroupSession]` dictionary keyed by invite code, persisted
to `UserDefaults` as JSON. Single-device only — invite codes resolve only
within the same device's storage. Useful for development without iCloud.

### 7.2 CloudKitService

Public-database CloudKit. Two record types:

**Group** record fields:
- `id: String` (UUID, also the recordName)
- `name: String`
- `inviteCode: String` *(must be Queryable)*
- `category: String`
- `createdAt: Date`
- `ownerID: String`
- `expiresAt: Date`
- `pendingNewExpiresAt: Date?`
- `pendingProposedAt: Date?`
- `pendingAcceptedMemberIDs: [String]?`

**Member** record fields:
- `id: String` (UUID, also the recordName)
- `groupID: CKRecord.Reference` *(action: deleteSelf, must be Queryable)*
- `displayName: String`
- `lastSeen: Date`
- `avatarData: Data` (Bytes)
- `latitude: Double?`, `longitude: Double?`

`CKRecord.Reference(action: .deleteSelf)` cascades: deleting a Group
record deletes its Member records.

### 7.3 CloudKit setup requirements (one-time, manual)

**Xcode**:
1. Target → Signing & Capabilities → + Capability → iCloud → check CloudKit.
2. Add a container; default `iCloud.<bundle>` is fine.
3. The entitlements file is auto-managed by Xcode.

**CloudKit Console** (after the first record is written from the app):
1. Container → Schema → Indexes.
2. On `Group`: mark `inviteCode` as **Queryable** (and ideally Sortable).
3. On `Member`: mark `groupID` as **Queryable**.
4. Container → Schema → Security Roles → `_icloud`:

   ```
   Group   →  Create ✓   Read ✓   Write ✓
   Member  →  Create ✓   Read ✓   Write ✓
   ```

`_world` should remain empty (no permissions).

Errors mapped:

- `.notAuthenticated` → `CloudKitError.notSignedIn`
- `.unknownItem` → `GroupServiceError.groupNotFound`
- `.invalidArguments` containing "queryable" →
  `CloudKitError.schemaIncomplete` (with a clear in-app message)

### 7.4 Polling refresh

Real-time push is **[planned]**. Today, while the dashboard is open,
`AppState.startGroupRefresh()` polls `groupService.fetchGroup(groupID:)`
every 10 seconds and merges:

- The fetched group replaces `currentGroup`.
- The local "self" entry in `members` is preserved (so an in-flight publish
  isn't clobbered by a stale fetch).
- `myGroups` is updated via `addOrUpdate`.

This is a stand-in for `CKQuerySubscription` + silent push, which is the
correct production solution but requires APNs setup and additional
entitlement work.

---

## 8. Notifications [shipped]

`NotificationService` wraps `UNUserNotificationCenter`. It schedules one
local notification per group:

- **Owner T-30 reminder** — fires 30 minutes before `expiresAt` with body
  `"<group name> expires in 30 minutes. Tap to extend."`. Only scheduled
  when the local user is the owner. Rescheduled on extension.

Tap handling: the service exposes
`notificationTaps: AsyncStream<NotificationTap>`. AppState consumes it and
calls `open(group:)`, deep-linking into the dashboard.

The `extensionProposed` notification type is defined in the protocol but not
yet scheduled — it will be wired when CloudKit subscriptions land (so a
non-owner device receives a push when the owner proposes an extension on
another device).

---

## 9. Offline Strategy [planned]

This is the longest design discussion in the project so far and shapes the
next major engineering effort. Summary of decisions:

### 9.1 Why BLE advertisements over Multipeer Connectivity

Two iOS-available short-range transports were considered:

| | Multipeer Connectivity | BLE advertisements |
|---|---|---|
| Setup | Heavy (session handshake) | None — broadcast and scan |
| Throughput | Kilobytes/sec | ~31 bytes/packet |
| Range | ~30 m | ~10–30 m |
| Battery | Higher | Lower |
| Background | Sessions die ~30 s after backgrounding | Scanning continues (throttled) |
| Peer count | ~7 hard limit | Unbounded |
| Use case | Rich data exchange | Position/identity broadcast |

For our core need ("see your group members in proximity when offline"),
**BLE advertisements are the right primitive.** They scale, run cheaper,
survive backgrounding better. Multipeer would only be justified for richer
offline data exchange (e.g., chat), which isn't core.

### 9.2 What goes into the advertisement

~31 bytes (legacy) or up to 255 bytes (extended advertising, iOS 15+).
Proposed legacy payload:

| Field                | Bytes | Notes                           |
|----------------------|-------|---------------------------------|
| Group hash           | 4     | Truncated SHA-256 of inviteCode |
| Member hash          | 4     | Truncated hash of memberID      |
| Compressed lat       | 4     | int32 fixed-point, 10⁻⁷°       |
| Compressed lon       | 4     | int32 fixed-point, 10⁻⁷°       |
| Timestamp            | 4     | seconds since group start       |
| Flags / reserved     | ~11   | accuracy, freshness, etc.       |

Devices filter on the group hash — they only show peers whose hash matches
the active group. This stops random nearby strangers' devices from
accidentally appearing.

### 9.3 The "magical compass" — gradient direction without UWB

Inspired by Find My on pre-U1 iPhones. Decision: **don't try to convert
RSSI to meters; use the sign of RSSI gradient over walking distance.**

Why this works:
- Absolute RSSI is corrupted by environment (a backpack subtracts ~20 dB,
  a wall ~10 dB, a body ~10 dB). Any meter estimate is unreliable.
- Those biases are roughly constant across a few seconds, so the
  *difference* between two readings while walking 5 m survives the noise.
- A gradient + walking heading + gyro orientation = a directional arrow.

Algorithm sketch:

1. Buffer the last ~10 seconds of `(timestamp, RSSI, location, heading)`
   per peer.
2. If the user has moved >2 m, run a small linear regression over
   `(displacement_x, displacement_y) → RSSI`. The negative gradient vector
   points toward the source.
3. Use `CMMotionManager.deviceMotion.attitude` to know which way the phone
   is facing in real-time (60 Hz).
4. Render a SwiftUI arrow rotated to the gradient bearing, smoothly tracked
   by gyro between BLE updates.
5. Confidence = R² of the regression fit. Low confidence → wider, fainter
   arrow + "Walk a bit so we can lock on" hint. High confidence → sharp,
   opaque arrow.

What this gives us:
- An AirTag-style compass on **every iPhone**, not just iPhone 11+.
- Works through walls, pockets, crowds — as long as the gradient survives.
- Works underground / no GPS — the compass is BLE-only.
- ±30° typical accuracy; bands like "Close / Nearby / Further off" for
  distance instead of meter values.

UWB / `NearbyInteraction` becomes an **upgrade**, not a requirement, for
users on iPhone 11+.

### 9.4 Background wake — tickle, not data

Decision: **background notifications are wake-up signals, not data
deliveries.**

iBeacon region monitoring lets iOS wake an app for ~10 seconds when a
matching beacon is detected, even from a force-quit state. We use this:

- Each device advertises an iBeacon packet alongside its richer GroupIn
  advertisement.
- Other devices register a `CLBeaconRegion` with the same UUID with
  `notifyOnEntry = true`.
- iOS detects → wakes app for ~10 s → app fires a local notification
  ("Open GroupIn — your group is nearby") → suspends.
- User taps notification → app opens → full BLE + compass kicks in.

This is intentionally low-information. Rich notifications ("Kian is at
37.7749, -122.4194") leak data via the notification system, complicate App
Review, and discourage the user from opening the app where the real
capabilities live.

Dedup logic during the wake window is the highest-risk piece — we must not
spam users every time someone passes within 30 m. Notify only on:

- First time this group session detects this peer
- A peer was lost for >5 min and reappeared
- The user has explicitly tapped "Looking for X" recently and X is now in
  range

### 9.5 Path log — passive iOS APIs, not gyro PDR

Original idea: dead-reckon a friend's path using gyroscope. **Rejected**
for non-walking modalities; gyro-based PDR fails on cars/trains/bikes
because the IMU senses the user's micro-motions, not the vehicle's, and
integration error compounds catastrophically.

Replaced with iOS's passive motion stack:

- **`CLLocationManager.startMonitoringSignificantLocationChanges()`** —
  Apple's low-power location service. Wakes the app every ~500 m of
  movement, any modality. Battery cost: nearly zero.
- **`CMMotionActivityManager`** — exposes Apple's classification (stationary,
  walking, running, automotive, cycling). Queryable historically.
- **`CMPedometer`** — steps + estimated distance for walking segments.
- **`CLLocationManager.startMonitoringVisits()`** — detects "stayed here for
  ≥10 min" events.

Combined: a path log that captures driving, walking, sitting, transit, all
at <3% extra daily battery. Stored locally on each phone, retrievable via a
BLE wake-and-query handshake when a friend is in proximity.

### 9.6 Hybrid mode — both transports always on

Decision: **don't switch between online and offline.** Run CloudKit and BLE
in parallel whenever the dashboard is open. Merge per member: newest
`lastSeen` wins.

User-visible state (planned indicator on the dashboard):

| State              | Description                                           |
|--------------------|-------------------------------------------------------|
| Online + Nearby    | CloudKit working, ≥1 BLE peer in range               |
| Online             | CloudKit working, no BLE peers                        |
| Nearby only        | No internet, ≥1 BLE peer                              |
| No connection      | No internet, no BLE peers (showing last known)        |

Network state from `NWPathMonitor` (`Network` framework). The combined
overhead is small — MPC's idle radio is cheap, CloudKit's failed requests
silently retry.

---

## 10. Find My — Handoff, Not Integration [planned]

Apple does **not** expose any third-party API to integrate with Find My,
FindMyFriends, or the offline finding network. We cannot:

- Programmatically initiate location sharing between users
- Read another user's Find My location
- Submit our app's "items" to the offline finding network
- Use Find My's mesh of iPhones to relay our data

What we *can* do is **bridge** users to Find My with one-tap actions:

- **Deep link**: `UIApplication.shared.open(URL(string: "findmy://"))` opens
  the Find My app. Undocumented scheme — fall back to the universal link
  `https://www.icloud.com/find` for safety.
- **Share sheet**: `UIActivityViewController` with a `CLLocation` payload
  presents the system share sheet, which on iOS includes Messages and may
  include Find My depending on the user's setup.
- **Coach**: in-app screenshots and instructions for the manual flow.

Planned UI surfaces:

- A small "Safety" section on the dashboard with **Also share via Find My**.
- A non-blocking suggestion card after creating a high-risk-category group:
  "💡 Set up Find My sharing with members for offline backup."
- A tooltip on a stale member's pin: "Last seen 38 min ago. Find My may
  have a more recent location."
- A toast when the local user has no internet for >5 min: "GroupIn can't
  reach others — Find My uses Apple's separate network."

Honest framing: GroupIn handles real-time group awareness; Find My is the
long-range backup. We coach the user, we don't pretend we can read its
data.

---

## 11. Privacy & Consent Model [shipped where applicable]

### 11.1 Identity

- **Per-group anonymity by default** (shipped). Memberships across groups
  carry unrelated UUIDs. Network-level snooping cannot correlate them.
- **Local profile is local.** Name and avatar live in UserDefaults; we never
  upload them outside the groups the user is in.

### 11.2 Group sharing

- **Symmetric.** Everyone sees everyone. There is no one-way watcher mode.
- **Time-bounded.** Owner picks the expiry. Hard delete when it hits.
- **Re-consent on extension.** If the owner extends, every other member
  must explicitly accept by the original expiry to remain. Members who
  don't accept are removed.

### 11.3 Future "Watch Over Me" / path query

For the planned background-tracking and remote-path-query features, the
consent rules we've committed to:

- **Pre-arranged, granular, time-bounded.** "Friend X may query my path for
  the next 8 hours" — not "X may always query."
- **Revocable instantly**, with no friend-side notification when revoked.
- **Reciprocal by default.** If X can query me, I can query X.
- **Visible audit trail.** Every query leaves a record the user can see.

These are App Review requirements as much as design choices.

---

## 12. Roadmap

### 12.1 Shipped

- MVVM scaffolding, `@Observable` AppState, env injection, NavigationStack
- Anonymous-per-group identity with profile editor and avatar cropper
- Six categories with tints, icons, default durations
- Group create / join / dashboard with copy-invite-code button
- Owner-set expiry, extension proposals, member acceptance, hard-delete
- Core Location best-accuracy with throttled CloudKit publish
- Find-My-style presence states + faded markers
- Per-member colors, fit-all map button, tap-to-focus with halo
- Polling refresh (10 s) and throttled location publish (10 s)
- Local notifications for owner T-30 reminder
- LocalGroupService and CloudKitService both fully implemented
- Onboarding gate before any group action

### 12.2 Phase 1 — BLE foundation [planned]

- Custom-advertisement broadcast and scan via `CoreBluetooth`
- Group-hash filter so only same-group peers register
- Peer position drawn on the map with a "via Bluetooth" indicator
- Plist additions: `NSBluetoothAlwaysUsageDescription`,
  `NSLocalNetworkUsageDescription`, relevant Bonjour services
- Foreground only

Estimated: ~5 days.

### 12.3 Phase 2 — Magical compass [planned]

- Full-screen "Finding X" view triggered from a member tap
- Gradient regression on RSSI samples, gyro fusion at 60 Hz
- Confidence-weighted arrow, "Walk to lock on" hint, haptic ticks
- Distance bands ("Close / Nearby / Further off") only — no meter claims

Estimated: ~5 days.

### 12.4 Phase 3 — iBeacon background wake [planned]

- iBeacon advertise alongside the rich BLE advert
- `CLBeaconRegion` registration with notifyOnEntry
- Tickle notifications with smart dedup
- Tap → deep link to dashboard

Estimated: ~5 days, with significant on-device testing.

### 12.5 Phase 4 — UWB precision finding [optional]

- `NearbyInteraction` session for iPhone 11+ pairs
- Compass auto-upgrades to UWB precision when available

Estimated: ~3–4 days.

### 12.6 Phase 5 — Offline messaging [optional]

- GATT-based short messages between in-range peers
- Foreground only

Estimated: ~3–4 days.

### 12.7 Watch Over Me mode [planned, parallel track]

- Continuous CloudKit publishing in background (foreground + background
  location modes)
- Significant location changes + motion activity + pedometer + visits
- Opt-in per group, time-bounded to group lifetime
- Solves the long-range online case for an unresponsive friend

Estimated: ~4–5 days.

### 12.8 Find My handoff [planned]

- Safety button + deep link
- Contextual nudges
- One-time "set up Find My backup" suggestion after creating a high-risk
  group

Estimated: <1 day.

### 12.9 Other planned but unscoped

- `CKQuerySubscription` for live updates (replaces 10 s polling)
- Adaptive accuracy throttling (HundredMeters ambient, Best on demand)
- iCloud sign-in preflight at app launch with a friendly nudge if
  signed out
- Move avatars from Bytes to `CKAsset` if storage becomes a concern
- Owner-initiated explicit cloud delete on swipe-remove
- Deaf-specific accessibility passes (haptic patterns, captions on every
  audio cue, larger touch targets)

---

## 13. Honest Limitations

- **iOS only.** Cross-platform support (Android) would require rebuilding
  the offline transport layer; Android's BLE is messier and the equivalent
  of NearbyInteraction is fragmented.
- **Foreground-biased.** Background BLE on iOS is throttled. Continuous
  precision tracking only works when the dashboard is open.
- **No long-range offline.** Find My's offline finding network is closed
  to third-party apps. We can't ride on Apple's mesh of iPhones.
- **Best-accuracy battery cost.** A 12-hour event with the dashboard kept
  open will roughly halve battery life. Adaptive accuracy is on the
  roadmap.
- **Polling, not push.** New members appear within 10 seconds (worst case
  20 s when both polling cycles align). `CKQuerySubscription` is the
  proper fix; we're waiting until APNs setup is justified.
- **Single-device test gap.** Most flows can be exercised on one device,
  but the multi-device acceptance flow for extensions can only be
  meaningfully tested with two iCloud accounts.
- **Scope-by-design.** GroupIn is not a chat app, not always-on tracking,
  not a friend network, not a profile system. The single relationship is
  "we're in the same group right now."

---

## 14. Setup Checklist (for a fresh checkout)

1. Open `GroupIn.xcodeproj` in Xcode 16+.
2. Confirm the deployment target (iOS 26) matches your devices.
3. Confirm `DEVELOPMENT_TEAM` in Build Settings is your team.
4. Decide on backend:
   - For local-only development: keep `useCloudKit = false` in
     `GroupInApp.swift`.
   - For cross-device testing:
     - Target → Signing & Capabilities → + Capability → iCloud → check
       CloudKit → add container.
     - Set `useCloudKit = true`.
     - Run the app once and create a group.
     - Open CloudKit Console, mark `Group.inviteCode` and `Member.groupID`
       as Queryable.
     - Set `_icloud` security role to Create + Read + Write on `Group` and
       `Member`. Leave `_world` empty.
5. Both test devices must be signed into iCloud (Settings → top of list).
6. Build & run.

---

*Last updated to reflect: anonymous-per-group identity, six activity
categories with City Exploring + Nature, owner-set expiry with re-consent
extension, CloudKit + LocalGroupService backends, the BLE + gradient-compass
+ iBeacon-wake offline plan, Watch Over Me design, and Find My handoff
strategy.*

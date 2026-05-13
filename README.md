# GroupIn

A proximity-first iOS app for finding people in your group when GPS and internet aren't available. Open the app to find your friends. Close it and your friends can still find you.

Designed for the disco-basement-ten-floors-underground use case: no cell signal, no Wi-Fi, no GPS lock — and you still want to know which way to walk to find your group.

---

## What it does

- Discovers nearby members over Bluetooth Low Energy.
- Shows a compass-style arrow pointing at each friend, using RSSI gradients + magnetic heading + dead reckoning when GPS isn't reliable.
- Falls back to MultipeerConnectivity (and, eventually, Wi-Fi Aware) for chat, event-log gossip, and avatar sync — anything bigger than a heartbeat.
- Wakes itself in the background when a friend's iBeacon advertisement is detected.
- Falls back to CloudKit when peers are out of physical range and the user has internet.
- Uses Ultra Wideband (when both devices have a U1/U2 chip and are within ~9 m) for sub-meter precision finding.

---

## Features and how well they actually work

Honest assessments per feature. "Working" means it's wired up end-to-end and behaves correctly under reasonable conditions; "Scaffolded" means the structural shape is in place but the substance is deferred; "New" means it landed in the recent six-phase architecture pass and hasn't been hardened against real-world venues yet.

### Core proximity finding

| Feature | Status | How well it works |
|---|---|---|
| BLE presence heartbeat | Working | ~30 m range. Reliable in foreground; in background you get ~10 s execution windows via state restoration. Force-quitting the app stops your phone from being findable until next launch. |
| RSSI-gradient compass | Working | Locks direction after the user walks 2+ meters. Typical accuracy 30–45°. Degrades in dense multipath (steel-frame buildings, crowded venues with bodies blocking line of sight). Exposes an R² confidence so the UI can show uncertainty honestly. |
| RSSI smoothing (Hampel filter) | New | Rejects single-sample wall/pocket spikes (>18 dB swing inside 0.5 s of the prior sample). Helps with momentary obstacles; doesn't fix sustained interference. |
| UWB precision finding | Working | Sub-meter ranging, sub-2° bearing — when it works. Requires both devices to have a U1/U2 chip (iPhone 11 and later) and to be within ~9 m. The compass auto-overrides to UWB readings when present. |
| Magnetic compass heading | Working | Works without GPS or internet — magnetometer + CoreLocation heading. Auto-recalibrates against drift, but steel-frame structures can perturb readings by 30–60° (elevators, basements). |
| Dead reckoning | Working | CoreMotion pedometer × magnetic heading from the last GPS anchor. Drifts roughly 5–10% of distance walked between anchors. Useful for "fill in the gap when GPS dies indoors"; not a substitute for a fresh fix. |
| Map view (MapLibre) | Working | Custom-tile rendering via the native MapLibre SDK. Works offline if tiles are cached; doesn't try to download fresh tiles without network. |

### Group management

| Feature | Status | How well it works |
|---|---|---|
| Group creation | Working | CloudKit-backed. Works offline — queues for retry until iCloud is reachable. |
| Invite codes + QR sharing | Working | Short alphanumeric codes shareable as a link or a QR. **No application-level encryption yet** (deferred to v2); MPC's built-in transport TLS protects the wire but not the invite code itself. |
| In-person join via BLE | Working | Joiner with no group and no internet can request the group identity from any in-range member; once they have it, they materialize the local session and sync the event log over the payload transport. |
| Member management (add/remove/ban) | Working | Driven through the unified event log; the reducer is idempotent so it doesn't matter whether an event arrives via local emit, transport gossip, or CloudKit. |
| Group extension proposals | Working | Owner proposes new expiry; members accept; the resolved event lands when threshold is reached. |
| Membership delivery status | Working | Tracks per-event delivery state (`.pending` → `.cloud` → `.delivered`) so the UI can show "received by everyone" markers. |

### Transport layer

| Feature | Status | How well it works |
|---|---|---|
| MultipeerConnectivity (MPC) | Working | ~30–100 m range depending on radio assist; megabit bandwidth; 8-peer cap per session. Occasional iOS-side flakiness on session setup — retry logic helps but isn't bulletproof. |
| Wi-Fi Aware (NAN) | Scaffolded | The `WiFiAwareService` conforms to the same `PayloadTransport` protocol; `start(...)` is a documented no-op pending iOS 26 framework integration. Capability negotiation reports `wifiAware = false` for this device, so the group-min selector consistently falls back to MPC for now. |
| Group-min capability negotiation | Working | Each device advertises its capabilities in `PeerPresence`; the router picks the highest-tier transport every member supports. With Wi-Fi Aware stubbed, every group lands on MPC; once the Wi-Fi Aware path is real, all-iOS-26 groups will auto-upgrade. |
| Payload-transport router | Working | Forwards async streams from the active child; `select(_:)` swaps transports cleanly with a restart if the router was active. |
| CloudKit out-of-range fallback | Working | Demoted to a fallback path; no longer promoted as primary. Reliable when online; mirrors events to CloudKit so out-of-range or rejoining members catch up. |

### Background and wake stack

| Feature | Status | How well it works |
|---|---|---|
| iBeacon region monitoring | Working | ~10 s wake on region entry. The most reliable background hook on iOS; survives force-quit on most devices. Used to fire "your friend is nearby" notifications without keeping a full BLE scan running. |
| CoreBluetooth state restoration | New | iOS resurrects the app on BLE events with `CBCentralManagerOptionRestoreIdentifierKey` and `CBPeripheralManagerOptionRestoreIdentifierKey`. Survives suspension. Force-quit recovery is iOS-version-dependent and not always granted. |
| Asymmetric seeker/sought roles | New | Foreground = seeker = full stack (BLE central + peripheral, payload transport, sensors, compass UI). Background = sought = BLE peripheral keeps advertising only. Materially reduces battery in the common case. |
| Background location keepalive | Working | "Always" location permission with `allowsBackgroundLocationUpdates = true` keeps the app running so BLE stays alive in pocket. iOS shows a visible indicator; users will see it and may turn off the permission. |
| Adaptive "walk a few steps" prompt | New | Heartbeat checks peer staleness. If every peer in the active group has gone >90 s without a refresh and we're the seeker, schedules a notification with a 15 s pre-fire delay (next peer update cancels it). Tunable; can still feel intrusive in marginal coverage. |

### Chat and event log

| Feature | Status | How well it works |
|---|---|---|
| Event-log gossip | Working | Cursor-based relay: peers compare event-log cursors via `PeerPresence`, and any peer ahead pushes the delta to peers behind. Idempotent at the reducer (event-ID dedup), so duplicate arrival is a no-op. |
| Chat (now event-based) | Working | Every chat message is just a `.chatMessage` event flowing through the same log. Persists to CloudKit when online; relayed over MPC when offline. No more separate "ephemeral chat characteristic" plumbing. |
| Avatar sync | Working | Now flows inline over the payload transport — the old `Event.strippedForBLE()` workaround (which removed avatars to fit BLE MTU) is gone. |

### Notifications

| Feature | Status | How well it works |
|---|---|---|
| Group expiry reminder | Working | Fires 30 minutes before scheduled expiry. |
| "Peer nearby" wake | Working | Fires on iBeacon region entry. Time-window-deduped (5 min) so a crowded venue doesn't spam the lock screen as users walk past each other. |
| Walk-around prompt | New | Soft nudge when state goes stale despite the transport being up. Honest about its limits — if iOS is throttling BLE in background, the user is the only path to recovery. |

### Identity and profile

| Feature | Status | How well it works |
|---|---|---|
| Apple Sign-In | Working | Uses the Apple ID for CloudKit user resolution. Identity is keyed by `CKUserRecordID` rather than per-install UUID so the same person across two devices is recognized. |
| Profile editor (display name, avatar) | Working | Local edits propagate through per-group user records and CloudKit. |
| Memoji avatar picker | Working | Native iOS sheet for Memoji selection; falls back to camera/photo library. |
| Per-group membership IDs | Working | Each group has its own membership UUID, so the same user shows up correctly across multiple simultaneous groups. |

### Other

| Feature | Status | How well it works |
|---|---|---|
| Haptic feedback | Working | Plays on key interactions; uses `CHHapticEngine`. |
| Accessibility (VoiceOver) | Working | Recent commits added VoiceOver labels + haptic confirmations across the major views. |
| Debug overlay | Working | Hidden surface for inspecting BLE diagnostics, transport diagnostics, event log state, pending emit queue, etc. Useful in the field. |

---

## Architecture in one paragraph

BLE is the **signal layer** — presence heartbeats, the join handshake, iBeacon background wake. Anything bigger (chat, event-log gossip, member roster, avatars) flows on the **payload layer**: MultipeerConnectivity today, Wi-Fi Aware behind the same `PayloadTransport` protocol once its framework wiring lands. The group picks the highest-tier transport every member supports (group-minimum capability negotiation). CloudKit is the **out-of-range fallback** — still wired, no longer primary. Compass uses an RSSI-gradient regression from your own movement plus magnetic heading plus pedometer dead-reckoning; UWB precision finding overrides when both devices have U-chips and are within range. Foreground users are *seekers* (full stack, full battery cost); backgrounded users are *sought* (BLE peripheral only, near-zero baseline cost).

---

## Requirements

- iOS 26.2 or later. (Wi-Fi Aware lives on iOS 26+; MPC works on every iOS version, but the project targets 26.2 minimum.)
- iPhone with Bluetooth Low Energy.
- UWB features require an Apple U1 or U2 chip (iPhone 11 and later).
- Permissions on first launch:
  - **Bluetooth** — required for any proximity feature.
  - **Local Network** — required for MultipeerConnectivity.
  - **Always location** — recommended for keeping presence alive in background. "When in Use" still works for foreground sessions.
  - **Motion** — required for dead reckoning and stationary detection.
  - **Notifications** — required for "peer nearby" and walk-around prompts.
  - **Nearby Interaction** — required for UWB precision finding.
  - **Camera** — required for scanning invite QR codes.
- iCloud account signed in for CloudKit sync.

---

## What isn't done yet

These were either deferred by design or scoped to a v2 pass.

- **End-to-end encryption.** Currently payloads transit MPC's transport TLS but aren't application-encrypted. The QR-based key exchange + AEAD wrapping + signed events plan is documented and ready to build; it's the next major phase.
- **Wi-Fi Aware framework wiring.** The transport conforms to the protocol but `start(...)` is a no-op. Real publisher/subscriber/data-path setup is the immediate follow-up once the framework's public API stabilizes.
- **Watch companion app.** Designed for v2 — wrist-tap engagement, tighter background story via WCSession, complication that updates while the phone is in a pocket.
- **Anchor-mesh coordinate sharing.** Each device's dead reckoning is in its own local frame today; sharing offsets between peers when they pass close together (so "my friend is 30 m northeast" is meaningful in your frame) is the next sensor-fusion phase.
- **Push-fanout server.** Considered and deferred. A tiny APNS-only server (no content, just wake pings) would unlock genuine on-demand background wake when peers have internet. The current build is device-only by choice.
- **Telemetry / crash reporting.** Nothing instrumented beyond debug overlays. Plan to wire in for the App Store build.

---

## Honest limitations

The hard ones, surfaced explicitly so users (and reviewers) know what they're getting:

- **Range is bounded by physics.** BLE: ~30 m. MPC: ~30–100 m. Beyond that you need internet (CloudKit) or to physically move closer. There is no magic.
- **Background reliability is bounded by iOS.** Wake windows are ~10 s. Sometimes you wake, can't bring up the payload transport in time, and only catch up on next foreground. The walk-around prompt is the fallback when the OS won't cooperate.
- **Force-quit stops you from being findable.** Swiping the app away in the multitasking switcher kills BLE peripheral advertising. State restoration sometimes resurrects on next event, but not always. This is documented behavior on iOS, not a bug.
- **Magnetometer is noisy indoors with metal.** Elevators, structural steel, large speakers all perturb heading. The compass auto-recalibrates but the user can see jitter.
- **Low Power Mode reduces background BLE frequency.** Below 20% battery, iOS throttles. Wakes still fire but less often.
- **MPC has an 8-peer cap.** Groups larger than 8 mesh through transitive relay — events hop peer-to-peer to reach everyone. Works, but adds delivery latency proportional to mesh depth.
- **No retroactive encryption migration.** When v2 lands and groups switch to encrypted events, existing event logs stay cleartext locally. Migration tooling is a v2 concern.
- **CloudKit is not zero-trust.** Events mirrored to CloudKit are visible to Apple and to anyone with the iCloud account's credentials. The P2P transport keeps content off Apple's servers when peers are physically together; CloudKit is the cost of out-of-range sync.

---

## Project status

Six-phase architecture pass complete (May 2026):

- **Phase 1** — Real MultipeerService implementation
- **Phase 2** — `PayloadTransport` protocol + router abstraction
- **Phase 3** — Chat and event-log gossip moved off BLE onto the payload transport (BLE retains presence, join handshake, iBeacon wake)
- **Phase 4** — Wi-Fi Aware scaffolding + group-min capability negotiation
- **Phase 5** — Asymmetric seeker/sought role split + CoreBluetooth state restoration
- **Phase 6** — RSSI smoothing in the compass engine + adaptive walk-around notifications

v2 scope: end-to-end encryption, Watch app, Wi-Fi Aware framework wiring, anchor-mesh coordinate sharing, optional push-fanout server.

---

## Building

```sh
open GroupIn.xcodeproj
```

Build target: `GroupIn`, scheme: `GroupIn`, destination: any iOS 26.2+ device or simulator. CloudKit features require a signed-in iCloud account on the device.

The project uses Xcode's `PBXFileSystemSynchronizedRootGroup`, so adding files under `GroupIn/` is automatically picked up — no manual `project.pbxproj` editing needed.

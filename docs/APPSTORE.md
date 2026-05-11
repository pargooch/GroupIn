# GroupIn — App Store Submission Readiness

This document tracks what's needed to ship GroupIn to the App Store and
what still has to land before submission. Status tags follow the same
convention as `TECH.md`:

- **[shipped]** — implemented and working in the current codebase
- **[planned]** — designed and committed to but not yet built
- **[blocker]** — App Review will reject without this; must ship before submission
- **[quality]** — won't trigger rejection, but degrades star rating or trust
- **[nice]** — defer-able to a follow-up release without harm
- **[deferred]** — scoped out of v1 on purpose

---

## 1. Current state

GroupIn is feature-complete for v1's core experience. The big architectural
pieces are all in place:

| Path | Feature | Status |
|------|---------|--------|
| A | Always-on tracking while in any group; closeDashboard / removeMyselfFromGroup / deleted-group reconciliation | **[shipped]** |
| B.1 | `PositionEstimate` with `source` provenance (gps / staleGPS / deadReckoning / interpolatedFromPeer / hypothetical); `LocationFix` with horizontal accuracy; source-aware pin rendering | **[shipped]** |
| B.2.1 | Dead reckoning via `CMPedometer` + heading integration; per-user step-length calibration (EWMA over GPS+pedometer windows, persisted) | **[shipped]** |
| B.2.2 | `.hypothetical` source publishing when no GPS this session; dashboard pins skip rendering for hypothetical members (member list still shows "No location yet") | **[shipped, partial]** |
| C.1+C.2 | `Event` model + custom-Codable `EventPayload` enum; `EventReducer`; `Event` CKRecord type; per-group event cursors; event emission alongside every mutation site | **[shipped]** |
| C.3 | BLE event gossip via dedicated `events` GATT characteristic; cursor exchange in `PeerPresence`; cursor-gated broadcast (no time/count gate); transitive relay through `handleGossipedEvent` | **[shipped]** |
| C.4.1 | Unified timeline UI (chat-as-event + structural-event system rows); paginated scroll-to-top history fetch with "Start of group" marker; persisted local event log | **[shipped]** |
| C.4.2 | Delivery dots (⏰ pending / ✓ cloud / ✓✓ delivered); cursor-on-User-record published via heartbeat; `reevaluateDeliveryStatus` after every sync | **[shipped]** |
| C.4.3 | Persisted `pendingEmits` retry queue; exponential backoff (5→10→20→40→60s cap); opportunistic drain on successful sync | **[shipped]** |
| — | Owner-only member removal + banlist with per-group salted SHA-256 hash (client-side enforced); Unban UI | **[shipped]** |
| — | QR code invite + scan; profile editor with photo/camera/Memoji; per-group anonymous identity | **[shipped]** |

---

## 2. Must-fix before submission [blocker]

These are the things App Review will reject without. None of them are heroic;
each is a small, well-scoped piece.

### 2.1 Account / data deletion flow

Apple requires apps with persistent server-side data to offer **in-app
account / data deletion** as of June 2022 (App Store Review Guideline 5.1.1(v)).
GroupIn stores group membership records on CloudKit's public database — this
clearly qualifies.

**What needs to ship:**
- A "Delete all my data" action in the Profile editor.
- On tap: confirmation alert ("This removes you from all groups and erases your
  local data. You can't undo this.").
- On confirm:
  - For each group in `myGroups`, call `groupService.leaveGroup(groupID:memberID:)`
    so the User CKRecord is removed server-side (already implemented for
    voluntary leaves).
  - For groups the user owns, call `groupService.deleteGroup(groupID:)` to
    cascade-delete the Group + Event + Member records.
  - Clear `myGroups`, `membershipByGroupID`, `eventsByGroup`, `eventCursors`,
    `oldestEventCursors`, `eventDeliveryByID`, `pendingEmits`, `peerCursors`,
    `localProfile` (reset to default), and the calibrated step length.
  - Tear down all subscriptions via `reconcileTrackingLifecycle`.
  - Navigate back to onboarding.

**Effort:** ~150 lines in `AppState.swift` + ~30 lines of UI in
`ProfileEditorView.swift`. Half a day of focused work.

### 2.2 Privacy nutrition label

App Store Connect requires a complete **App Privacy** section. Mismatch with
actual app behavior = rejection.

**Data Collected** entries we must declare:

| Category | Item | Linked to user? | Used for tracking? |
|---------|------|-----------------|---------------------|
| Location | Precise Location | Yes (tied to anonymous CloudKit ID) | No |
| Identifiers | User ID (anonymous CKUserRecordID hash) | Yes | No |
| Photos and Videos | Photos (profile picture) | Yes | No |
| User Content | Other User Content (chat messages) | Yes | No |
| Diagnostics | Crash Data (once MetricKit lands) | No | No |
| Identifiers | Device ID (group ban hash, salted per-group) | No — not correlatable across groups by design | No |

Linked-to-user flag is the load-bearing field here. CloudKit ties data to the
user's iCloud account; the user can identify themselves via that account, so
the data IS linked to them in App Review's framing — even though we don't see
their real identity.

### 2.3 Privacy policy URL

Required for any app accessing location, photos, camera, or persistent data
storage. We use all four.

**What needs to ship:**
- A static markdown page on GitHub Pages (or any free host) documenting:
  - What data we collect (mirrors §2.2 table)
  - How it's used (group presence sharing, moderation, never sold)
  - How users can delete their data (the §2.1 flow)
  - Contact email
- URL goes into App Store Connect's "Privacy Policy URL" field.

Half a day, including the github-pages setup.

### 2.4 App icon

The Assets catalog needs a complete icon set:
- 1024×1024 for App Store
- All required iPhone sizes (20, 29, 40, 60, 76, 83.5 in @2x/@3x)
- iOS 17+ accepts a single 1024×1024 with `single-size` mode, but legacy
  backstops are still worth providing.

Until this is filled out, archive builds fail with an icon-missing warning.

### 2.5 Launch screen

A `LaunchScreen.storyboard` or SwiftUI launch screen via `UILaunchScreen` in
Info.plist. Currently missing — the default white screen briefly shows on
launch, which App Review tolerates but isn't a great first impression.

A simple branded launch screen with the app icon centered on the accent
color is enough.

### 2.6 Pre-prompt for "Always" location authorization

App Review explicitly looks for a clear pre-prompt UI before the system
"Always" location dialog appears, otherwise the rejection note is:
> *"Apps that use Always location must explain to users why before showing
> the system prompt."*

**What needs to ship:**
- A SwiftUI sheet explaining why GroupIn needs "Always" — "to wake the app
  when group members come near you, even when the app is closed."
- Triggered on first group create/join (when we'd otherwise call
  `requestAlwaysAuthorization` blindly).
- "Continue" → system prompt fires. "Not now" → app falls back to
  "When in Use" mode silently; group dashboard still works but the iBeacon
  wake-up feature is gated off.

Probably 100 lines of code + a clean explanatory illustration.

---

## 3. Should-fix for production quality [quality]

These won't block submission. They'll show up as 1-star reviews from users
who hit edge cases the simulator doesn't expose.

### 3.1 Silent error swallowing

Lots of code paths use `try?` and `catch { /* nothing */ }`. For user-visible
flows (create group, join, photo upload, chat send), surface the error in
an alert / toast. The diagnostic infrastructure already exists — the
`mapCKError` improvements in `CloudKitService` produce actionable copy like
*"CloudKit field 'groupID' isn't queryable."* We just need to route those
into UI in more places.

### 3.2 Owner-leaves-own-group / last-member-leaves edge cases

Currently:
- Owner cannot leave their own group (UI hides the button correctly,
  defensively-checked in `removeMyselfFromGroup`).
- Last-member-leaves of a non-owner-managed group: undefined.
- Group's owner leaves the group via account deletion (§2.1): orphans the
  group on CloudKit forever (until natural expiry).

The right behavior:
- When the owner deletes their account, also `deleteGroup(groupID:)` on
  every group they own.
- When the last non-owner member leaves a group: probably no action
  (group keeps its owner, will hard-delete on expiry).

Easy follow-up to §2.1's account deletion flow.

### 3.3 Invite codes brute-forceable

6 characters from a 32-symbol alphabet = ~1 billion combinations. A
determined attacker could brute-force their way into a target group.
CloudKit doesn't give us rate limiting on `joinGroup` predicates.

Two pragmatic fixes:
- Bump invite codes to **8 characters** (~1 trillion combos) — fast and
  cheap, breaks no existing code paths.
- Or rate-limit join attempts client-side (max 5 attempts per minute on a
  single device) — gentler but only stops casual abuse.

Recommended: just go to 8 chars. Existing groups with 6-char codes
continue to work; new groups get 8.

### 3.4 Crash reporting

Add **MetricKit** (free, Apple-native) to capture crash + hang reports.
Tiny code addition (~30 lines) — register as a `MXMetricManagerSubscriber`,
log delivered payloads to disk, optionally upload to a free aggregator
later.

Without this, production users hit bugs that we never see and can't fix.

### 3.5 Loading states

Many async operations show no visible indicator while running. Create
group, join group, profile editor photo upload all have proper progress
states already. The gaps are:
- Pull-to-refresh on dashboard: SwiftUI handles this natively ✓
- Compass UWB session start: no spinner during the ~1-2s warmup
- Older-events fetch via timeline scroll-to-top: the empty-cell sentinel
  is the only signal — could be more explicit

Minor polish; not blocking.

### 3.6 CloudKit schema migration safety

Whenever we add a CKRecord field, existing records have to handle missing
values gracefully. The current code defends against this everywhere
(`as? Type` everywhere in `CloudKitRecordMapping`), and the `EventPayload`
custom Codable rejects unknown event types cleanly.

One worth-noting pattern: when adding a *new* event type in the future,
older clients will throw `DecodingError` on the unknown kind. That's
acceptable — they'll skip the event and continue — but it does mean older
clients run with stale state until they update.

For App Store v1: no action needed. Watch for this when shipping v1.1.

---

## 4. Nice-to-have (defer to follow-up) [nice]

### 4.1 Localization scaffold

All user-facing strings are currently hardcoded English. Moving them to
`Localizable.strings` is cheap to do now and expensive to retrofit later
across thousands of strings.

Action: pull strings through `String(localized:)` or `LocalizedStringKey`
literals. No actual translations needed for v1 — English-only base.
Future translations slot into separate `.lproj` directories without code
changes.

### 4.2 Onboarding tutorial

Three swipeable cards on first launch explaining the value prop:
1. "Find your group in any crowd" — map screenshot
2. "Works without internet" — BLE icon + offline message visualization
3. "Anonymous, short-lived, no accounts" — privacy highlights

Currently the welcome screen jumps straight to profile setup. Adding
context cards before that improves Day-1 retention.

### 4.3 TestFlight beta

Recruit 5–10 real users for 1–2 weeks before submitting to App Review.
Catches battery / BLE / iCloud-account-edge-case bugs that no simulator
will surface.

### 4.4 Accessibility audit

Use Apple's free Accessibility Inspector tool on macOS. Things to verify:
- Dynamic Type scaling on every text element
- VoiceOver labels and traversal order
- Hit targets ≥ 44pt on every interactive element
- Reduced Motion respects animation suppression
- Color contrast ratios in dark mode

Most accessibility labels are already in place; this is a verification
pass, not a build-from-scratch.

---

## 5. Deferred from v1 [deferred]

### 5.1 Cross-peer hypothetical origin + multilateration

The full Path B.2.2 vision: when no member has GPS, the group establishes
a shared relative coordinate frame; positions are computed via multi-peer
BLE range measurements (multilateration); the frame anchors to real-world
coordinates the moment any one peer gets a GPS fix.

**Why deferred:** weeks of focused work. Requires:
- Cross-peer origin consensus protocol (built on the event log)
- Multi-vantage-point position aggregation (multilateration math, noise
  handling)
- Anchor-on-first-GPS conversion (geometric transformation of the entire
  relative frame to absolute coords)

What's shipped instead: a member with no GPS is rendered as "no location
yet" rather than at fake coordinates. Visually honest, no fake-GPS
confusion.

### 5.2 Server-side ban enforcement (CloudKit Functions)

Currently the ban gate is client-side: `JoinGroupViewModel` checks
`isLocalUserBanned` before publishing membership. A modified IPA could
skip the check.

The clean fix is **CloudKit Functions** (Apple's serverless layer
announced at WWDC 2024) — server-side gates on the `appendEvent` and
`createMember` paths. Apple is steering moderation features in this
direction.

For App Store v1: client-side enforcement is acceptable. Document this
as a known limitation; plan the CloudKit Functions migration for v2.

### 5.3 Real BLE event fragmentation

Currently `Event.strippedForBLE()` removes `avatarData` from
`memberJoined` payloads before broadcast, so every event fits in a single
GATT write (~185 bytes). If a future event type grows past that, we'll
need actual fragmentation. Not an issue for the current 9 event types.

### 5.4 Local event-log eviction (LRU)

`eventsByGroup` grows unbounded locally. For chat-heavy groups over many
months, this could accumulate megabytes of JSON on disk. The paginated
fetch infrastructure for older events already exists — the eviction
strategy is just: keep state events forever, drop chat events older than
30 days, re-fetch via `loadOlderEvents` on demand.

Add when telemetry shows real bloat, not before.

---

## 6. CloudKit Console — one-time schema setup

Before submitting, deploy the production schema. These steps are
one-time per environment (Development + Production).

1. Open https://icloud.developer.apple.com/dashboard → your container.
2. **Schema → Indexes**:
   - `Group.inviteCode` — **Queryable** (required for `joinGroup`)
   - `Member.groupID` — **Queryable** (required for `fetchMembers`)
   - `Event.groupID` — **Queryable** (required for `fetchEvents`)
   - `Event.createdAt` — **Sortable** (required for paginated history)
3. **Schema → Deploy Schema Changes** to push Development → Production.

Development and Production schemas are separate. Debug builds use
Development; TestFlight and App Store builds use Production. **Skipping
the production deploy is the most common pre-submission mistake** —
debug builds work fine on your phone, but real users on TestFlight hit
empty member lists and stuck joins.

---

## 7. Pre-submission checklist

Work through this in order. Every item maps to a section above.

- [ ] Account / data deletion flow (§2.1)
- [ ] Privacy nutrition label filled in App Store Connect (§2.2)
- [ ] Privacy policy URL set + page published (§2.3)
- [ ] App icon complete in Assets catalog (§2.4)
- [ ] Launch screen (§2.5)
- [ ] Always-location pre-prompt (§2.6)
- [ ] Schema deployed to Production (§6)
- [ ] Recruit 5+ TestFlight beta users (§4.3)
- [ ] Beta-tester feedback addressed
- [ ] Crash reporting wired up (§3.4)
- [ ] Invite codes bumped to 8 chars (§3.3) — optional but recommended
- [ ] Run Accessibility Inspector audit pass (§4.4)
- [ ] App Review Notes drafted: short description of the offline / BLE
      feature, mention iBeacon background wake-up so the reviewer doesn't
      flag it
- [ ] Background mode justification ready: `location` for sharing while
      app is closed; `remote-notification` for CloudKit silent push
- [ ] Submit

---

## 8. Notes on Apple Developer Academy demo vs App Store submission

The codebase was built for the Apple Developer Academy "Champagne" final
challenge with a 5-person team (Novin, Aida, Olga, Anastazia, Vittorio),
but is being prepared for App Store launch afterward. The implication
that runs through every decision in this doc:

- Privacy strings must be **honest about long-term behavior**, not just
  the demo flow.
- Error states must have **user-visible recovery paths**, not silent
  fails.
- Identity primitives prefer **stable Apple-provided IDs**
  (`CKUserRecordID`) over per-install UUIDs where reinstall-survival
  matters (bans, moderation features).
- The academy demo is a milestone, **not the finish line** — code
  decisions don't get a free pass because "we'll fix it before
  submission." If we're going to fix it before submission, fix it now.

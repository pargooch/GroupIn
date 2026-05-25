//
//  HomeView.swift
//  GroupIn
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    #if DEBUG
    @State private var showDebugOverlay = false
    #endif

    var body: some View {
        // Banners + empty-state live OUTSIDE the List in plain
        // VStacks so the List's section count and ForEach contents
        // stay stable across state changes. The previous layout had
        // a conditional Section for banners (count changed when
        // bluetoothReady flipped during BLE scanning) and an
        // if/else swap between `emptyGroupsState` and `ForEach`
        // inside the groups Section — both classic triggers for the
        // UICollectionView "invalid number of items in section N"
        // assertion that was terminating the app. Plain SwiftUI
        // containers above/below a List with strictly-stable
        // sections sidesteps the entire crash class.
        VStack(spacing: 0) {
            bannersStack
            List {
                profileSection
                createJoinSection
                groupsSection
            }
        }
        .navigationTitle("GroupIn")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .toolbar {
            // Dev-only diagnostic surface. Tap to open the overlay
            // showing retry queues, BLE health, peer cursors, last
            // events — the single fastest way to diagnose "is
            // anything stuck?" without grepping logs.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showDebugOverlay = true
                } label: {
                    Image(systemName: "ladybug")
                }
                .accessibilityLabel("Debug overlay")
            }
        }
        .sheet(isPresented: $showDebugOverlay) {
            DebugOverlayView()
        }
        #endif
    }

    private struct StatusBanner: Identifiable {
        let id: String
        let icon: String
        let title: String
        let body: String
        let tint: Color
    }

    private var statusBanners: [StatusBanner] {
        var banners: [StatusBanner] = []
        switch appState.iCloudAccountStatus {
        case .available, .couldNotDetermine:
            // .couldNotDetermine is the optimistic default — don't flash
            // a banner before CloudKit has had a chance to reply.
            break
        case .noAccount:
            banners.append(StatusBanner(
                id: "icloud",
                icon: "icloud.slash",
                title: "Sign in to iCloud",
                body: "GroupIn syncs locations through your iCloud account. Open Settings → Apple ID to sign in.",
                tint: .red
            ))
        case .restricted:
            banners.append(StatusBanner(
                id: "icloud",
                icon: "lock.icloud",
                title: "iCloud is restricted",
                body: "Parental controls or device management are blocking iCloud. GroupIn needs it to sync.",
                tint: .red
            ))
        case .temporarilyUnavailable:
            banners.append(StatusBanner(
                id: "icloud",
                icon: "exclamationmark.icloud",
                title: "iCloud is temporarily unavailable",
                body: "Your account is being reconfigured. Try again in a moment.",
                tint: .orange
            ))
        }
        if !appState.bleDiagnostics.bluetoothReady {
            banners.append(StatusBanner(
                id: "ble",
                icon: "antenna.radiowaves.left.and.right.slash",
                title: "Bluetooth is off",
                body: "Turn Bluetooth on so GroupIn can find nearby members and exchange location offline.",
                tint: .orange
            ))
        }
        // Pending-uploads indicator: when CloudKit is unreachable
        // (offline, schema mismatch, account issues), groups created
        // and events emitted locally accumulate in the retry queues.
        // The user sees their groups + chat work normally — this
        // banner is the honest signal that some of it hasn't reached
        // the cloud yet.
        let pending = appState.pendingUploadCount
        if pending > 0 {
            banners.append(StatusBanner(
                id: "pending",
                icon: "arrow.up.circle.dotted",
                title: pending == 1
                    ? "1 item waiting to sync"
                    : "\(pending) items waiting to sync",
                body: "GroupIn keeps working offline. We'll upload your changes the moment iCloud is reachable again.",
                tint: .blue
            ))
        }
        return banners
    }

    /// Banners stack rendered above the List (NOT as a List section).
    /// Plain VStack so banners can appear/disappear freely without
    /// invalidating the List's section indices. Empty banners yield
    /// an empty VStack which collapses to zero height.
    @ViewBuilder
    private var bannersStack: some View {
        let banners = statusBanners
        if !banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(banners) { banner in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: banner.icon)
                            .font(.title3)
                            .foregroundStyle(banner.tint)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(banner.title)
                                .font(.subheadline.weight(.semibold))
                            Text(banner.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(banner.tint.opacity(0.08))
                    )
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Section {
            Button {
                appState.path.append(.profileEditor)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(data: appState.localProfile.avatarData,
                               name: appState.localProfile.displayName,
                               size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(needsProfileSetup
                             ? "Set up your profile"
                             : appState.localProfile.displayName)
                            .font(.headline)
                        Text(needsProfileSetup
                             ? "Add a name and photo to get started"
                             : "Edit profile")
                            .font(.caption)
                            .foregroundStyle(needsProfileSetup
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(needsProfileSetup
                               ? "Opens the profile editor to set your name and photo"
                               : "Opens your profile to edit name and photo")
        }
    }

    /// Groups section. Always a `ForEach` — even when there are zero
    /// groups, the section just produces zero rows and the empty
    /// placeholder is rendered as a section *footer* below. Keeping
    /// the section's row-producer constant (always ForEach over
    /// `myGroups`) means the List diff never sees a view-type swap
    /// between "empty placeholder" and "list of rows".
    @ViewBuilder
    private var groupsSection: some View {
        Section {
            ForEach(appState.myGroups) { group in
                let isOwner = group.ownerID == appState.currentUser.id
                Button {
                    appState.open(group: group)
                } label: {
                    groupRow(group)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens group \(group.name)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        appState.remove(group: group)
                    } label: {
                        Label(
                            isOwner ? "Delete" : "Leave",
                            systemImage: isOwner
                                ? "trash"
                                : "rectangle.portrait.and.arrow.right"
                        )
                    }
                }
            }
        } header: {
            // Hide the section header when there are no groups so the
            // empty-state hero below stands on its own instead of
            // sitting under a lonely "Your groups" label. Header
            // content can vary freely — it isn't counted in the List
            // row diff, so this can't trip the section-count assertion.
            if !appState.myGroups.isEmpty {
                Text("Your groups")
            }
        } footer: {
            if appState.myGroups.isEmpty {
                emptyGroupsState
            }
        }
    }

    private var needsProfileSetup: Bool {
        appState.localProfile.needsOnboarding
    }

    @ViewBuilder
    private var createJoinSection: some View {
        Section {
            Button {
                appState.path.append(needsProfileSetup ? .profileEditor : .createGroup)
            } label: {
                Label("Create a Group", systemImage: "plus.circle.fill")
            }
            .accessibilityHint(needsProfileSetup
                               ? "Opens profile setup first"
                               : "Starts a new group you can invite others to")

            Button {
                appState.path.append(needsProfileSetup ? .profileEditor : .joinGroup)
            } label: {
                Label("Join a Group", systemImage: "person.badge.plus")
            }
            .accessibilityHint(needsProfileSetup
                               ? "Opens profile setup first"
                               : "Join an existing group with an invite code")
        } footer: {
            if needsProfileSetup {
                Text("Set up your profile above to create or join a group.")
            }
        }
    }

    /// Empty-state placeholder rendered as the groups Section's
    /// footer. Footers aren't counted as rows in the List diff so
    /// showing/hiding this can't trigger the "invalid number of
    /// items in section" assertion that bit us when the same
    /// placeholder lived as a Section row alongside an `if/else`
    /// ForEach swap.
    @ViewBuilder
    private var emptyGroupsState: some View {
        VStack(spacing: 20) {
            EmptyGroupsHero()

            VStack(spacing: 8) {
                Text("Find your people")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Create a group or join with a code — then see everyone in real time, online or off.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No groups yet. Create a group or join with a code to find your friends.")
    }

    @ViewBuilder
    private func groupRow(_ group: GroupSession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(group.category.tint.opacity(0.18))
                Image(systemName: group.category.systemImage)
                    .foregroundStyle(group.category.tint)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                // Live presence bridges Home to the neon dashboard /
                // compass: each member shows as a colored dot in their
                // assigned color, glowing when they're live. Recompute
                // on a 15 s tick so freshness decays even while Home
                // stays open.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    presenceRow(group: group, now: context.date)
                }
                metaLine(group: group)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(group))
    }

    /// Member-color dot cluster + a "sharing" summary. The dots use the
    /// same per-member palette as the map markers and compass, so a
    /// group's people are recognizable across every surface.
    @ViewBuilder
    private func presenceRow(group: GroupSession, now: Date) -> some View {
        let statuses = group.members.map {
            PresenceStatus(lastSeen: $0.lastSeen,
                           hasFix: $0.coordinate != nil,
                           now: now)
        }
        let activeCount = statuses.filter(\.isActivelySharing).count

        HStack(spacing: 8) {
            memberDots(group: group, now: now)

            if activeCount > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("\(activeCount) active")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            } else {
                Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Up to four overlapping member-color dots, with a "+N" overflow.
    /// Live members are fully saturated and glow; everyone else is
    /// dimmed — the dot brightness honestly tracks `lastSeen` freshness.
    @ViewBuilder
    private func memberDots(group: GroupSession, now: Date) -> some View {
        let maxDots = 4
        let shown = Array(group.members.prefix(maxDots))
        let overflow = group.members.count - shown.count

        HStack(spacing: -5) {
            ForEach(shown) { member in
                let color = Color.memberColor(for: member.id)
                let status = PresenceStatus(lastSeen: member.lastSeen,
                                            hasFix: member.coordinate != nil,
                                            now: now)
                Circle()
                    .fill(color.opacity(status.isActivelySharing ? 1.0 : 0.4))
                    .frame(width: 13, height: 13)
                    .overlay(
                        Circle().strokeBorder(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            lineWidth: 1.5
                        )
                    )
                    .shadow(color: status.isLive ? color.opacity(0.9) : .clear,
                            radius: status.isLive ? 3 : 0)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 9)
            }
        }
        .accessibilityHidden(true)
    }

    /// Invite code + expiry on one muted line. Expiry turns orange when
    /// the group is within 30 minutes of ending (or has a pending
    /// extension); the code stays secondary regardless.
    @ViewBuilder
    private func metaLine(group: GroupSession) -> some View {
        let urgent = group.expiresAt.timeIntervalSinceNow < 30 * 60
        let expiryTint: Color = urgent ? .orange : .secondary

        HStack(spacing: 4) {
            Text("Code \(group.inviteCode)")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Image(systemName: group.hasPendingExtension ? "clock.arrow.circlepath" : "clock")
                .foregroundStyle(expiryTint)
            Text("Expires \(group.expiresAt, style: .relative)")
                .foregroundStyle(expiryTint)
            if group.hasPendingExtension {
                Text("· extension pending")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
    }

    /// Spoken summary for the whole row: category, name, how many
    /// members are active, and when it expires.
    private func rowAccessibilityLabel(_ group: GroupSession) -> String {
        let count = group.members.count
        let activeCount = group.members.filter {
            PresenceStatus(lastSeen: $0.lastSeen,
                           hasFix: $0.coordinate != nil).isActivelySharing
        }.count

        var parts = ["\(group.category.label) group \(group.name)"]
        parts.append("\(count) member\(count == 1 ? "" : "s")")
        if activeCount > 0 {
            parts.append("\(activeCount) active")
        }
        parts.append("expires \(group.expiresAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Empty-state radar hero

/// The first-run hero: a neon "radar" that visualizes what GroupIn
/// does — *you* at the center (the glowing cyan core), and friends
/// (member-color dots) waiting to be found, with sonar pulses sweeping
/// outward across faint range rings. It reuses the compass's electric-
/// cyan accent and the same per-member palette as the map markers, so
/// the empty screen already feels like the rest of the app.
///
/// Every animation is gated behind `accessibilityReduceMotion`: with
/// Reduce Motion on, the pulses are dropped and the dots/core render
/// as a single still frame — the radar still looks complete, it just
/// stops moving.
private struct EmptyGroupsHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Electric cyan — the compass's "reactor core" accent. Kept in
    /// sync with `CompassView.orbAccent` so the brand color reads the
    /// same on the first screen as on the finding screen.
    private static let accent = Color(red: 0.30, green: 0.92, blue: 1.00)

    private let canvas: CGFloat = 210
    private static let ringDiameters: [CGFloat] = [84, 144, 204]

    /// Orbiting "friends," spaced ~120° apart at varied radii so the
    /// composition reads as a scatter rather than a clock face. Colors
    /// are drawn straight from the member palette.
    private let dots: [(color: Color, angle: Double, radius: CGFloat)] = [
        (.cyan,  20,  96),
        (.green, 140, 88),
        (.pink,  250, 80)
    ]

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Self.accent.opacity(0.16), .clear],
                center: .center,
                startRadius: 4,
                endRadius: canvas / 2
            )

            rangeRings

            if !reduceMotion {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        sonarPulse(phase: phase(t, offset: 0))
                        sonarPulse(phase: phase(t, offset: 0.5))
                    }
                }
            }

            memberDots
            core
        }
        .frame(width: canvas, height: canvas)
        .accessibilityHidden(true)
    }

    private var rangeRings: some View {
        ZStack {
            ForEach(Self.ringDiameters, id: \.self) { d in
                Circle()
                    .strokeBorder(Self.accent.opacity(0.14), lineWidth: 1)
                    .frame(width: d, height: d)
            }
        }
    }

    /// 0→1 saw wave with a phase offset, so two pulses can ride the
    /// same clock half a cycle apart for a continuous sweep.
    private func phase(_ t: TimeInterval, offset: Double) -> Double {
        let period = 3.4
        return ((t / period) + offset).truncatingRemainder(dividingBy: 1)
    }

    /// One expanding ring that grows from the core and fades as it
    /// reaches the outer range ring.
    private func sonarPulse(phase: Double) -> some View {
        let scale = 0.2 + phase * 0.8          // 0.2 → 1.0
        let opacity = (1 - phase) * 0.4
        return Circle()
            .strokeBorder(Self.accent.opacity(opacity), lineWidth: 1.5)
            .frame(width: canvas, height: canvas)
            .scaleEffect(scale)
    }

    private var memberDots: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30,
                                paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(dots.enumerated()), id: \.offset) { index, dot in
                    let breath = reduceMotion
                        ? 1.0
                        : (0.88 + 0.12 * sin(t * 1.8 + Double(index) * 1.3))
                    let rad = dot.angle * .pi / 180
                    Circle()
                        .fill(dot.color)
                        .frame(width: 14, height: 14)
                        .shadow(color: dot.color.opacity(0.9), radius: 6)
                        .shadow(color: dot.color.opacity(0.5), radius: 13)
                        .scaleEffect(breath)
                        .offset(x: dot.radius * CGFloat(sin(rad)),
                                y: -dot.radius * CGFloat(cos(rad)))
                }
            }
        }
    }

    /// "You" — the radar origin. A bright cyan core inside a soft halo.
    private var core: some View {
        ZStack {
            Circle()
                .fill(Self.accent.opacity(0.25))
                .frame(width: 42, height: 42)
                .blur(radius: 9)
            Circle()
                .fill(Self.accent)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .shadow(color: Self.accent.opacity(0.9), radius: 8)
        }
    }
}

#Preview("Empty") {
    NavigationStack { HomeView() }
        .environment(AppState())
}

#Preview("With groups") {
    let state = AppState()
    let me = User(displayName: "Me")
    state.myGroups = [
        GroupSession(name: "Coachella", inviteCode: "ABC234",
                     category: .festival,
                     ownerID: me.id,
                     expiresAt: .now.addingTimeInterval(3600 * 12),
                     members: [me]),
        GroupSession(name: "Italy Trip", inviteCode: "ZX9KQM",
                     category: .trip,
                     ownerID: me.id,
                     expiresAt: .now.addingTimeInterval(86400 * 5),
                     members: [me, User(displayName: "Alex")]),
        GroupSession(name: "Yosemite", inviteCode: "FAM345",
                     category: .nature,
                     ownerID: me.id,
                     expiresAt: .now.addingTimeInterval(86400 * 2),
                     members: [me])
    ]
    return NavigationStack { HomeView() }
        .environment(state)
}

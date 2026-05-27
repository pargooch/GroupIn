//
//  GroupDashboardView.swift
//  GroupIn
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

struct GroupDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: GroupDashboardViewModel
    @State private var showsLocationHelp = false
    @State private var compassMember: User?
    @State private var showsChat = false
    @State private var showsInviteQR = false
    @State private var memberToRemove: User?
    @State private var confirmingLeaveGroup = false
    /// Currently route-targeted peer on the neon map. Tapping their
    /// pin draws a glowing route between us and them; tapping again
    /// (or tapping empty map) clears.
    @State private var routeTargetID: UUID?
    /// Bumped by the scope button to tell `MapLibreMapView` to re-fit
    /// every member into view. Counter-based so repeated taps work.
    @State private var fitAllTrigger: Int = 0
    /// Detent of the Find My–style dashboard drawer over the map.
    /// Opens at half height.
    @State private var sheetDetent: PresentationDetent = .fraction(0.5)
    /// Last seen member-ID set, so we can fire a success haptic AND
    /// a VoiceOver announcement only when someone *new* joins (not
    /// when someone leaves), and name them in the announcement.
    @State private var lastMemberIDs: Set<UUID> = []
    /// Tracks the prior value of the owner's "should extend" prompt
    /// so we only buzz once on the false→true transition.
    @State private var lastShouldPromptExtend = false

    init(viewModel: GroupDashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            .toolbar { dashboardToolbar }
            .modifier(DashboardModifiers(viewModel: viewModel))
    }

    /// Presentation surfaces (sheets, full-screen cover, alerts) live
    /// on the drawer rather than the root view: the drawer is always
    /// the topmost presented view, so anything presented from the root
    /// would otherwise be trapped behind it.
    private func dashboardPresentations<Content: View>(
        _ content: Content
    ) -> some View {
        content
            .sheet(isPresented: $showsLocationHelp) {
                LocationHelpSheet()
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $compassMember) { member in
                CompassView(memberID: member.id)
                    .environment(appState)
            }
            .sheet(isPresented: $showsChat) {
                ChatSheet()
                    .environment(appState)
            }
            .sheet(isPresented: $showsInviteQR) {
                if let group = viewModel.group {
                    InviteQRSheet(
                        groupName: group.name,
                        inviteCode: group.inviteCode
                    )
                }
            }
            .alert(
                "Remove \(memberToRemove?.displayName ?? "this member")?",
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                presenting: memberToRemove
            ) { member in
                Button("Cancel", role: .cancel) { memberToRemove = nil }
                Button("Remove", role: .destructive) {
                    let id = member.id
                    memberToRemove = nil
                    Task { await appState.removeMember(id) }
                }
            } message: { _ in
                Text("They'll be removed from this group and added to the banlist — they can't rejoin with the invite code unless you unban them.")
            }
            .alert(
                "You were removed from \(appState.bannedFromGroupName ?? "the group")",
                isPresented: Binding(
                    get: { appState.bannedFromGroupName != nil },
                    set: { if !$0 { appState.bannedFromGroupName = nil } }
                )
            ) {
                Button("OK") { appState.bannedFromGroupName = nil }
            } message: {
                Text("The group owner removed you. Ask them to invite you again if you'd like to rejoin.")
            }
            // Surfaces when a refresh discovers the active group was
            // hard-deleted server-side (owner pressed Delete, or it
            // expired and was cleaned up).
            .alert(
                "\(appState.groupDeletedNotice ?? "This group") was deleted",
                isPresented: Binding(
                    get: { appState.groupDeletedNotice != nil },
                    set: { if !$0 { appState.groupDeletedNotice = nil } }
                )
            ) {
                Button("OK") { appState.groupDeletedNotice = nil }
            } message: {
                Text("The group's owner deleted it. It's been removed from your list.")
            }
            // Leave-this-group confirmation. Fired by the destructive
            // button in the dashboard's group section.
            .alert(
                "Leave \(viewModel.group?.name ?? "this group")?",
                isPresented: $confirmingLeaveGroup
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Leave", role: .destructive) {
                    guard let groupID = viewModel.group?.id else { return }
                    Task { await appState.removeMyselfFromGroup(groupID) }
                }
            } message: {
                Text("You'll be removed from this group and stop sharing your location with its members. You can rejoin later with the invite code.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let group = viewModel.group {
            groupList(group: group)
                // No nav-bar title: the group name + member count are
                // already shown once in the drawer header (which stays
                // visible even when the drawer is collapsed), so a
                // nav-bar title would just duplicate it over the map.
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "No active group",
                systemImage: "questionmark.circle",
                description: Text("This group is no longer available.")
            )
        }
    }

    /// Find My–style layout: the neon map fills the whole screen and
    /// the dashboard rides in a draggable drawer on top of it. The
    /// drawer opens at half height; drag down to reveal the full map,
    /// up for the full dashboard.
    @ViewBuilder
    private func groupList(group: GroupSession) -> some View {
        mapPane(group: group)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                dashboardList(group: group)
                    .presentationDetents(
                        [.height(120), .fraction(0.5), .large],
                        selection: $sheetDetent
                    )
                    .presentationBackgroundInteraction(
                        .enabled(upThrough: .fraction(0.5))
                    )
                    .presentationDragIndicator(.visible)
                    .presentationBackground(
                        Color(uiColor: .systemBackground).opacity(0.4)
                    )
                    .interactiveDismissDisabled()
            }
    }

    /// Non-scrolling header at the top of the drawer. Because it isn't
    /// part of the scrollable List, the sheet can be dragged between
    /// detents by grabbing anywhere on it — a far bigger target than
    /// the thin drag indicator alone.
    @ViewBuilder
    private func drawerHeader(group: GroupSession) -> some View {
        HStack(spacing: 12) {
            // The ONLY place the group's identity is shown: category
            // symbol + name + member count.
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(group.category.tint.opacity(0.18))
                    Image(systemName: group.category.systemImage)
                        .foregroundStyle(group.category.tint)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(group.name), \(group.members.count) members")

            Spacer(minLength: 8)

            messagesButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func dashboardList(group: GroupSession) -> some View {
        dashboardPresentations(
            VStack(spacing: 0) {
                drawerHeader(group: group)

                List {
                    // Four always-rendered sections. Section count is
                    // constant regardless of `isOwner` or banlist
                    // contents — every conditional that used to gate
                    // a whole Section now lives INSIDE the section as
                    // content variation. Avoids the "invalid number
                    // of items in section N" UICollectionView
                    // assertion that was crashing this view on the
                    // joiner side as soon as the dashboard mounted.
                    membersSection(group: group)
                    groupSection(group: group)
                    bannedSection(group: group)
                    leaveGroupSection(group: group)
                }
                .scrollContentBackground(.hidden)
            .onAppear {
                lastMemberIDs = Set(group.members.map(\.id))
                lastShouldPromptExtend = viewModel.shouldPromptOwnerToExtend
            }
            .onChange(of: group.members.map(\.id)) { _, newIDs in
                let newSet = Set(newIDs)
                let added = newSet.subtracting(lastMemberIDs)
                if !lastMemberIDs.isEmpty, !added.isEmpty {
                    HapticEngine.shared.notify(.success)
                    let names = added
                        .compactMap { id in group.members.first(where: { $0.id == id })?.displayName }
                        .joined(separator: ", ")
                    let phrase = added.count == 1
                        ? "\(names) joined the group"
                        : "\(names) joined the group"
                    VoiceGuidance.shared.announce(phrase)
                }
                lastMemberIDs = newSet
            }
            .onChange(of: viewModel.shouldPromptOwnerToExtend) { _, newValue in
                if newValue, !lastShouldPromptExtend {
                    HapticEngine.shared.notify(.warning)
                    VoiceGuidance.shared.announce(
                        "Group expires soon. You can extend it from the Group section.",
                        priority: .high
                    )
                }
                lastShouldPromptExtend = newValue
            }
            }
        )
    }

    @ViewBuilder
    private func groupSection(group: GroupSession) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                shareInviteButton()

                expiryRow(group: group)
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func expiryRow(group: GroupSession) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let isUrgent = group.expiresAt.timeIntervalSinceNow < 30 * 60
            let tint: Color = isUrgent ? .orange : .secondary

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text("Expires \(group.expiresAt, style: .relative)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(tint)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(group.expiresAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if viewModel.shouldPromptOwnerToExtend {
                        Button {
                            viewModel.showExtendSheet = true
                        } label: {
                            Text("Extend")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .accessibilityElement(children: .combine)

                if let pending = group.pendingExtension {
                    pendingBanner(group: group, pending: pending)
                }
            }
        }
    }

    /// Single entry point for inviting people. Replaces the old
    /// copy-pill + separate QR button pair: every invite path (QR for
    /// in-person, copyable code, system share sheet) now lives behind
    /// this one control, inside `InviteQRSheet`. The code stays visible
    /// here so the owner can read it at a glance without opening the
    /// sheet.
    @ViewBuilder
    private func shareInviteButton() -> some View {
        Button {
            showsInviteQR = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                Text("Share Invite")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                // The code is long now (it doubles as the E2E key), so we
                // don't show it inline — just a label. The full code + QR
                // live in the sheet this opens.
                Text("Invite code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .accessibilityHidden(true)

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Share invite")
        .accessibilityHint("Opens the invite sheet with a QR code and sharing options")
    }

    /// The map pane pinned to the top half of the dashboard.
    @ViewBuilder
    private func mapPane(group: GroupSession) -> some View {
        ZStack(alignment: .topTrailing) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                MapLibreMapView(
                    members: group.members,
                    currentMemberID: appState.currentUser.id,
                    now: context.date,
                    focusedMemberID: $routeTargetID,
                    fitAllTrigger: $fitAllTrigger,
                    colorScheme: colorScheme
                )
            }
            fitAllButton
                .padding(12)
                .padding(.top, 44)
        }
        .overlay(alignment: .bottomLeading) {
            if routeTargetID == nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    mapLocationStatus(now: context.date)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottom) {
            focusedMemberCard(group: group)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .accessibilityLabel("Map showing your location and group members")
    }

    /// Compact location-sharing status shown as plain text in the
    /// bottom-left of the map — replaces the old list section.
    @ViewBuilder
    private func mapLocationStatus(now: Date) -> some View {
        switch appState.locationAuthorizationStatus {
        case .notDetermined:
            mapStatusText("Requesting permission…",
                          color: .white.opacity(0.85),
                          tappable: false)

        case .denied, .restricted:
            mapStatusText("Location off — tap for help",
                          color: .red,
                          tappable: true)

        case .authorizedWhenInUse, .authorizedAlways:
            if viewModel.currentUser.coordinate != nil {
                let state = LocationFreshness(
                    lastSeen: viewModel.currentUser.lastSeen,
                    now: now
                )
                mapStatusText(state.title,
                              color: state.color,
                              tappable: state != .live)
            } else {
                mapStatusText("Acquiring location…",
                              color: .white.opacity(0.85),
                              tappable: false)
            }

        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mapStatusText(_ text: String,
                               color: Color,
                               tappable: Bool) -> some View {
        let label = HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.7), radius: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)

        if tappable {
            Button { showsLocationHelp = true } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to learn why")
        } else {
            label
        }
    }

    /// Floating dark card pinned to the bottom of the map when a
    /// peer is route-targeted. Mirrors the reference design's
    /// "Louise 10km · 5min ago" surface so the user knows who the
    /// glowing route is pointing at and can jump straight to the
    /// compass / chat for them.
    @ViewBuilder
    private func focusedMemberCard(group: GroupSession) -> some View {
        if let id = routeTargetID,
           let member = group.members.first(where: { $0.id == id }) {
            let color = Color.memberColor(for: member.id, among: group.members.map(\.id))
            let distance = distanceFromCurrentUser(to: member, group: group)
            HStack(spacing: 12) {
                AvatarView(data: member.avatarData,
                           name: member.displayName,
                           size: 40,
                           tint: color)
                    .overlay(
                        Circle().strokeBorder(color, lineWidth: 2)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        if let distance {
                            Text(distance)
                        }
                        Text("·")
                        Text(member.lastSeen, style: .relative)
                        Text("ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Button {
                    compassMember = member
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(color.opacity(0.25), in: Circle())
                        .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                }
                .accessibilityLabel("Find \(member.displayName)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay(
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: color.opacity(0.6), radius: 14, x: 0, y: 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.smooth(duration: 0.3), value: routeTargetID)
        }
    }

    private func distanceFromCurrentUser(to other: User,
                                         group: GroupSession) -> String? {
        guard let mine = group.members.first(where: { $0.id == appState.currentUser.id })?.coordinate,
              let theirs = other.coordinate else { return nil }
        let meters = CLLocation(latitude: mine.latitude, longitude: mine.longitude)
            .distance(from: CLLocation(latitude: theirs.latitude, longitude: theirs.longitude))
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    @ViewBuilder
    private var connectionModePill: some View {
        let mode = appState.connectionMode
        HStack(spacing: 6) {
            Image(systemName: mode.icon)
                .font(.caption2)
            Text(mode.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(mode.tint.opacity(0.4), lineWidth: 1)
        )
        .foregroundStyle(mode.tint)
        .accessibilityLabel(mode.accessibilityLabel)
    }

    @ViewBuilder
    private var fitAllButton: some View {
        Button {
            // Bump the trigger to ask `NeonMapView` for a fresh
            // fit-all. Counter increment guarantees `updateUIView`
            // sees the change even when the user taps it repeatedly.
            fitAllTrigger += 1
        } label: {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .accessibilityLabel("Fit all members on map")
    }

    /// Non-owner-only "Leave Group" action. Owners can't appear here
    /// because for them the right verb is "Delete group entirely,"
    /// which lives as a swipe action on Home. Keeping the button at
    /// the bottom of the dashboard matches iOS Settings convention —
    /// destructive actions hide at the foot of the screen so users
    /// don't tap them on the way past.
    @ViewBuilder
    private func leaveGroupSection(group: GroupSession) -> some View {
        // Always rendered. Content vanishes for owners (they delete
        // via the existing remove-group flow) but the *Section
        // itself* stays put. Previous version was an outer
        // `if !isOwner { Section }` which made the section count
        // depend on a runtime flag — the cause of the diff crash.
        Section {
            if !viewModel.isOwner {
                Button(role: .destructive) {
                    confirmingLeaveGroup = true
                } label: {
                    Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.neonDestructive)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .listRowSeparator(.hidden)
                .accessibilityHint("Removes you from this group and stops sharing your location with its members")
            }
        }
        .listRowBackground(Color.clear)
    }

    /// Owner-only banlist UI. Hidden when the group has no banned
    /// members so the dashboard doesn't carry empty sections. Each
    /// row offers an Unban button that re-opens the group to the
    /// previously-removed person.
    @ViewBuilder
    private func bannedSection(group: GroupSession) -> some View {
        // ALWAYS render this Section so the dashboard's section count
        // is constant. When the user isn't the owner, OR there are
        // no banned members, the section yields zero rows and no
        // header/footer (entire Section becomes invisible). What was
        // previously `if condition { Section { ... } }` triggered a
        // UICollectionView assertion every time the condition
        // flipped — appearing/disappearing sections is what blew up
        // the List diff.
        let showBanlist = viewModel.isOwner && !group.bannedMembers.isEmpty
        Section {
            if showBanlist {
                ForEach(group.bannedMembers) { entry in
                    bannedRow(entry)
                }
            }
        } header: {
            if showBanlist {
                Text("Banned (\(group.bannedMembers.count))")
            }
        } footer: {
            if showBanlist {
                Text("Banned members can't rejoin with the invite code. Tap Unban to let them back in.")
                    .font(.caption)
            }
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func bannedRow(_ entry: BannedMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: "person.fill.xmark")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body.weight(.medium))
                Text("Banned \(entry.bannedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let hash = entry.banHash
                Task { await appState.unbanMember(banHash: hash) }
            } label: {
                Text("Unban")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unban \(entry.displayName)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.displayName), banned \(entry.bannedAt, style: .relative) ago")
    }

    @ViewBuilder
    private func membersSection(group: GroupSession) -> some View {
        // Section structure is *strictly stable*: always a ForEach
        // (which yields zero rows when members is empty) plus an
        // optional footer for the empty placeholder. Previously this
        // section did `if isEmpty { Text } else { ForEach }`, which
        // is a view-type swap that SwiftUI's List diff handles with
        // the "invalid number of items in section N" assertion the
        // moment members goes from 0 → N or vice versa. Footer
        // content is supplementary and not counted as a row in the
        // diff, so showing/hiding it never trips the diff.
        Section {
            ForEach(group.members) { member in
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    memberRow(member, group: group, now: context.date)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if viewModel.isOwner
                        && member.id != viewModel.currentUser.id
                        && member.id != group.ownerID {
                        Button(role: .destructive) {
                            memberToRemove = member
                        } label: {
                            Label("Remove", systemImage: "person.fill.xmark")
                        }
                    }
                }
            }
        } footer: {
            if group.members.isEmpty {
                Text("No members yet").foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        if viewModel.group != nil {
            if viewModel.isOwner {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showExtendSheet = true
                    } label: {
                        Label("Extend", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityHint("Propose a new expiry for this group")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // "Done" — pops the dashboard back to Home without
                // touching the tracking stack. Sharing keeps running
                // (location, beacon, heartbeat, push subscription
                // are all driven by myGroups now, not currentGroup).
                // Explicit leave / delete happens via the Leave Group
                // button below or swipe-delete on Home.
                Button("Done") {
                    appState.closeDashboard()
                }
                .fontWeight(.semibold)
                .accessibilityHint("Closes this group view and returns home. You stay a member.")
            }
        }
    }

    // MARK: - Expiry / extension UI

    @ViewBuilder
    private func pendingBanner(group: GroupSession, pending: PendingExtension) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Extension proposed")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            Text("New expiry: \(pending.newExpiresAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
            Text("\(pending.acceptedMemberIDs.count + 1) of \(group.members.count) accepted")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.canAcceptExtension {
                Button {
                    Task { await viewModel.acceptExtension() }
                } label: {
                    Text("Accept extension")
                }
                .buttonStyle(.neon)
                .padding(.top, 4)
            } else if !viewModel.isOwner {
                Label("You've accepted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Messages (offline BLE chat)

    /// Chat entry point — a small circular button on the trailing edge
    /// of the group-name row.
    @ViewBuilder
    private var messagesButton: some View {
        Button {
            showsChat = true
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
        }
        .buttonStyle(.neonIcon(tint: .accentColor, diameter: 46))
        .overlay(alignment: .topTrailing) {
            if !appState.chatMessages.isEmpty {
                Circle()
                    .fill(.red)
                    .frame(width: 11, height: 11)
                    .overlay(
                        Circle().strokeBorder(Color(.systemBackground), lineWidth: 2)
                    )
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(appState.chatMessages.isEmpty
                            ? "Messages"
                            : "Messages, \(appState.chatMessages.count) unread")
        .accessibilityHint("Opens the group chat")
    }

    // MARK: - Helpers

    private enum LocationFreshness: Equatable {
        case live
        case slow
        case stalled

        init(lastSeen: Date, now: Date) {
            let age = now.timeIntervalSince(lastSeen)
            if age < 30 { self = .live }
            else if age < 120 { self = .slow }
            else { self = .stalled }
        }

        var color: Color {
            switch self {
            case .live:    return .green
            case .slow:    return .orange
            case .stalled: return .red
            }
        }

        var title: String {
            switch self {
            case .live:    return "Sharing live"
            case .slow:    return "Slow connection"
            case .stalled: return "Can't share location"
            }
        }
    }

    // MARK: - Member row

    @ViewBuilder
    private func memberRow(_ member: User,
                           group: GroupSession,
                           now: Date) -> some View {
        let status = PresenceStatus(
            lastSeen: member.lastSeen,
            hasFix: member.coordinate != nil,
            now: now
        )
        let hasLocation = member.coordinate != nil
        let isMe = member.id == viewModel.currentUser.id
        let memberColor = Color.memberColor(for: member.id, among: group.members.map(\.id))

        HStack(spacing: 12) {
            Button {
                guard hasLocation, !isMe else { return }
                let willClear = routeTargetID == member.id
                routeTargetID = willClear ? nil : member.id
                if willClear {
                    HapticEngine.shared.tick()
                } else {
                    HapticEngine.shared.impact(.light)
                }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(data: member.avatarData,
                               name: member.displayName,
                               size: 40,
                               tint: memberColor)
                        .overlay(
                            Circle().strokeBorder(
                                routeTargetID == member.id ? memberColor : .clear,
                                lineWidth: 2.5
                            )
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(member.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if isMe {
                                Text("You")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.tint)
                            }
                            if member.id == group.ownerID {
                                Image(systemName: "crown.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        // Presence (and any "no location" note) sits on
                        // a second line so the name always has the full
                        // row width and never has to squeeze.
                        HStack(spacing: 6) {
                            PresenceBadge(status: status)
                                .accessibilityHidden(true)
                            if !hasLocation {
                                Text("No location yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasLocation || isMe)

            // Compass / Find is available regardless of whether the
            // peer currently has a coordinate. Indoors, no member
            // has a coordinate (CoreLocation can't fix), so gating
            // this button on `hasLocation` is exactly wrong — that's
            // the moment the user most needs the BLE / UWB indoor
            // compass. The compass view's own bearing cascade handles
            // missing-GPS gracefully and falls through to BLE gradient
            // or UWB direction. The route-on-map button above still
            // needs `hasLocation` (it draws a line on the map and a
            // missing coordinate is meaningless there).
            if !isMe {
                Button {
                    compassMember = member
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(memberColor)
                        .background(memberColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color(uiColor: .systemBackground).opacity(0.4),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(memberColor, lineWidth: 2.5)
                .shadow(color: memberColor.opacity(0.95), radius: 4)
                .shadow(color: memberColor.opacity(0.6), radius: 9)
        )
        // Treat the whole row as a single VoiceOver element. The
        // interactive parts (toggle route, find with compass) are
        // exposed as custom actions so a blind user can swipe to
        // each row, hear its summary, and choose what to do via the
        // rotor without hunting individual hit targets.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memberAccessibilityLabel(member,
                                                     group: group,
                                                     status: status,
                                                     isMe: isMe,
                                                     hasLocation: hasLocation))
        .accessibilityValue(routeTargetID == member.id ? "Route drawn on map" : "")
        .accessibilityHint(hasLocation && !isMe
                           ? "Double tap to toggle the route on the map."
                           : "")
        .accessibilityAction(named: routeTargetID == member.id
                             ? "Clear route on map"
                             : "Draw route on map") {
            guard hasLocation, !isMe else { return }
            let willClear = routeTargetID == member.id
            routeTargetID = willClear ? nil : member.id
        }
        .accessibilityAction(named: "Open compass to find \(member.displayName)") {
            // Compass works without a coordinate (BLE / UWB fallback);
            // don't gate on hasLocation. See sibling button above.
            guard !isMe else { return }
            compassMember = member
        }
    }

    /// Builds the spoken summary for a member row: name, distance,
    /// direction relative to the user, presence, owner / me badges.
    private func memberAccessibilityLabel(_ member: User,
                                          group: GroupSession,
                                          status: PresenceStatus,
                                          isMe: Bool,
                                          hasLocation: Bool) -> String {
        var parts: [String] = [member.displayName]
        if isMe { parts.append("you") }
        if member.id == group.ownerID { parts.append("group owner") }

        if !hasLocation {
            parts.append("no location yet")
        } else if !isMe,
                  let mine = group.members.first(where: { $0.id == appState.currentUser.id })?.coordinate,
                  let theirs = member.coordinate {
            let meCL = CLLocation(latitude: mine.latitude, longitude: mine.longitude)
            let themCL = CLLocation(latitude: theirs.latitude, longitude: theirs.longitude)
            let metres = meCL.distance(from: themCL)
            let bearing = SpatialFormatter.bearingDegrees(
                from: meCL.coordinate, to: themCL.coordinate
            )
            parts.append(SpatialFormatter.distance(meters: metres))
            parts.append(SpatialFormatter.direction(
                bearing: bearing,
                userHeading: appState.currentUser.heading
            ))
        }

        parts.append(status.accessibilitySummary)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Modifiers
//
// Bundling lifecycle, sheet, alert, and onChange into a ViewModifier keeps
// the main `body` simple enough for the type checker.

private struct DashboardModifiers: ViewModifier {
    @Bindable var viewModel: GroupDashboardViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showExtendSheet) {
                if let group = viewModel.group {
                    ExtendGroupSheet(currentExpiresAt: group.expiresAt) { newDate in
                        await viewModel.proposeExtension(newExpiresAt: newDate)
                    }
                }
            }
            .onAppear {
                viewModel.start()
                viewModel.fitInitialIfNeeded()
            }
            .onDisappear { viewModel.stop() }
            .onChange(of: viewModel.currentUser.coordinate) { _, _ in
                viewModel.fitInitialIfNeeded()
            }
            .onChange(of: viewModel.group?.members.count) { _, _ in
                viewModel.fitInitialIfNeeded()
            }
            .alert("Action failed",
                   isPresented: Binding(
                    get: { viewModel.actionError != nil },
                    set: { if !$0 { viewModel.actionError = nil } }
                   )) {
                Button("OK", role: .cancel) { viewModel.actionError = nil }
            } message: {
                Text(viewModel.actionError ?? "")
            }
    }
}

#Preview {
    let state = AppState()
    let me = User(displayName: "Me")
    state.currentGroup = GroupSession(
        name: "Weekend Hike",
        inviteCode: "ABC234",
        ownerID: me.id,
        expiresAt: .now.addingTimeInterval(3600 * 3),
        members: [me]
    )
    state.currentUser = me
    return NavigationStack {
        GroupDashboardView(
            viewModel: GroupDashboardViewModel(
                appState: state,
                groupID: state.currentGroup!.id
            )
        )
    }
    .environment(state)
}

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
    @Environment(\.openURL) private var openURL
    @State private var viewModel: GroupDashboardViewModel
    @State private var didCopyInviteCode = false
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
    /// Drives the draggable bottom sheet listing members by distance.
    @State private var showsMemberList = false

    init(viewModel: GroupDashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            .toolbar { dashboardToolbar }
            .modifier(DashboardModifiers(viewModel: viewModel))
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
                .navigationTitle(group.name)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "No active group",
                systemImage: "questionmark.circle",
                description: Text("This group is no longer available.")
            )
        }
    }

    @ViewBuilder
    private func groupList(group: GroupSession) -> some View {
        @Bindable var vm = viewModel
        List {
            mapSection(group: group)
            if showsLocationStatus {
                Section { locationStatusContent }
            }
            expirySection(group: group)
            groupSection(group: group)
            membersSection(group: group)
            if viewModel.isOwner {
                bannedSection(group: group)
            }
            messagesSection
            safetySection
            leaveGroupSection(group: group)
        }
        // Pull-to-refresh — forces a CloudKit fetch on demand so the
        // user doesn't have to wait for the 10s polling tick or a
        // silent-push delivery. Especially useful when CloudKit
        // subscriptions are delayed (which they often are on first
        // launch after a schema change).
        .refreshable {
            await appState.refreshCurrentGroupManually()
        }
    }

    /// We always show the location section now — either with a permission
    /// prompt, an "acquiring…" spinner, or a small live freshness indicator.
    /// Helps the user see at a glance whether GPS is actively producing
    /// fixes, which matters most when offline.
    private var showsLocationStatus: Bool { true }

    @ViewBuilder
    private func groupSection(group: GroupSession) -> some View {
        Section("Group") {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(group.category.tint.opacity(0.18))
                    Image(systemName: group.category.systemImage)
                        .foregroundStyle(group.category.tint)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.medium))
                    Text(group.category.label)
                        .font(.caption)
                        .foregroundStyle(group.category.tint)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)

            inviteCodeButton(code: group.inviteCode)
        }
    }

    @ViewBuilder
    private func inviteCodeButton(code: String) -> some View {
        HStack(spacing: 12) {
            Button {
                copyInviteCode(code)
            } label: {
                HStack {
                    Text("Invite Code")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(code)
                        .foregroundStyle(.secondary)
                    Image(systemName: didCopyInviteCode ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopyInviteCode ? Color.green : Color.accentColor)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Invite code \(code), tap to copy")

            Button {
                showsInviteQR = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show invite QR code")
        }
    }

    @ViewBuilder
    private func mapSection(group: GroupSession) -> some View {
        Section {
            ZStack(alignment: .topTrailing) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    MapLibreMapView(
                        members: group.members,
                        currentMemberID: appState.currentUser.id,
                        now: context.date,
                        focusedMemberID: $routeTargetID,
                        fitAllTrigger: $fitAllTrigger
                    )
                }
                VStack(spacing: 10) {
                    membersButton(group: group)
                    fitAllButton
                }
                .padding(12)
            }
            .overlay(alignment: .bottom) {
                focusedMemberCard(group: group)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .frame(height: 540)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .accessibilityLabel("Map showing your location and group members")
            .sheet(isPresented: $showsMemberList) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    MemberListSheet(
                        members: group.members,
                        currentMemberID: appState.currentUser.id,
                        now: context.date,
                        focusedMemberID: $routeTargetID
                    )
                    .environment(appState)
                }
                .presentationDetents([.height(120), .fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
            }
        }
    }

    @ViewBuilder
    private func membersButton(group: GroupSession) -> some View {
        Button {
            showsMemberList = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.footnote.weight(.semibold))
                Text("\(group.members.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .accessibilityLabel("Show members list")
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
            let color = Color.memberColor(for: member.id)
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
        if !viewModel.isOwner {
            Section {
                Button(role: .destructive) {
                    confirmingLeaveGroup = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                            .labelStyle(.titleAndIcon)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Removes you from this group and stops sharing your location with its members")
            }
        }
    }

    /// Owner-only banlist UI. Hidden when the group has no banned
    /// members so the dashboard doesn't carry empty sections. Each
    /// row offers an Unban button that re-opens the group to the
    /// previously-removed person.
    @ViewBuilder
    private func bannedSection(group: GroupSession) -> some View {
        if !group.bannedMembers.isEmpty {
            Section {
                ForEach(group.bannedMembers) { entry in
                    bannedRow(entry)
                }
            } header: {
                Text("Banned (\(group.bannedMembers.count))")
            } footer: {
                Text("Banned members can't rejoin with the invite code. Tap Unban to let them back in.")
                    .font(.caption)
            }
        }
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
        Section("Members (\(group.members.count))") {
            if group.members.isEmpty {
                Text("No members yet").foregroundStyle(.secondary)
            } else {
                // Each member is its own List row. The TimelineView
                // is per-row (cheap — SwiftUI shares the timer source)
                // so swipe actions and row separators behave like
                // every other List in the app. Previously we wrapped
                // the whole ForEach in one TimelineView + VStack,
                // which collapsed every member into a single List row
                // and made swipe-to-remove apply to "all members at
                // once."
                ForEach(group.members) { member in
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        memberRow(member, group: group, now: context.date)
                    }
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
    private func expirySection(group: GroupSession) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Expires \(group.expiresAt, style: .relative)")
                                .font(.body.weight(.medium))
                            Text(group.expiresAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    if let pending = group.pendingExtension {
                        pendingBanner(group: group, pending: pending)
                    }

                    if viewModel.shouldPromptOwnerToExtend {
                        Button {
                            viewModel.showExtendSheet = true
                        } label: {
                            Label("Extend before it expires", systemImage: "exclamationmark.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
            }
        } header: {
            Text("Expiry")
        }
    }

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
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
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

    // MARK: - Location authorization

    @ViewBuilder
    private var locationStatusContent: some View {
        switch appState.locationAuthorizationStatus {
        case .notDetermined:
            HStack(spacing: 8) {
                ProgressView()
                Text("Requesting permission…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                Label("Location access is off", systemImage: "location.slash")
                    .foregroundStyle(.red)
                Text("Enable location for GroupIn in Settings to share your position with the group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .accessibilityHint("Opens the iOS Settings app")
                }
            }
            .accessibilityElement(children: .combine)

        case .authorizedWhenInUse, .authorizedAlways:
            if viewModel.currentUser.coordinate != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    locationFreshnessRow(now: context.date)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Acquiring location…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

        @unknown default:
            Text("Unknown location authorization state.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Messages (offline BLE chat)

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            Button {
                showsChat = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Messages")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Send short notes to nearby members over Bluetooth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !appState.chatMessages.isEmpty {
                        Text("\(appState.chatMessages.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Messages")
        }
    }

    // MARK: - Safety / Find My handoff

    @ViewBuilder
    private var safetySection: some View {
        Section {
            Button {
                openFindMy()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.18))
                        Image(systemName: "location.viewfinder")
                            .foregroundStyle(.green)
                    }
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up Find My backup")
                            .foregroundStyle(.primary)
                            .font(.body.weight(.medium))
                        Text("Apple's separate network — works at longer range when GroupIn can't reach.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Find My app so you can share your location as a backup")
        } header: {
            Text("Safety")
        } footer: {
            Text("GroupIn handles real-time group awareness. Find My runs through Apple's network — useful as a long-range backup when our signal can't reach.")
                .font(.caption)
        }
    }

    private func openFindMy() {
        // Try the native scheme first; fall back to the universal link
        // (which iOS routes into the Find My app on devices that have it,
        // and to the iCloud web UI otherwise).
        guard let scheme = URL(string: "findmy://"),
              let universal = URL(string: "https://www.icloud.com/findmy") else {
            return
        }
        openURL(scheme) { accepted in
            if !accepted {
                openURL(universal)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func locationFreshnessRow(now: Date) -> some View {
        let state = LocationFreshness(
            lastSeen: viewModel.currentUser.lastSeen,
            now: now
        )
        Button {
            if state != .live { showsLocationHelp = true }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.color)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let detail = state.detail(lastSeen: viewModel.currentUser.lastSeen) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if state != .live {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == .live)
        .accessibilityHint(state == .live ? "" : "Tap to learn why")
    }

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

        func detail(lastSeen: Date) -> String? {
            switch self {
            case .live:
                return nil
            case .slow:
                return "Last update \(lastSeen.formatted(.relative(presentation: .named)))"
            case .stalled:
                return "Tap to learn why"
            }
        }
    }

    private func copyInviteCode(_ code: String) {
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didCopyInviteCode = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyInviteCode = false
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
        let memberColor = Color.memberColor(for: member.id)

        HStack(spacing: 12) {
            Button {
                viewModel.focus(on: member)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(data: member.avatarData,
                               name: member.displayName,
                               size: 40,
                               tint: memberColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(member.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
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
                                    .accessibilityLabel("Owner")
                            }
                        }
                        if !hasLocation {
                            Text("No location yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasLocation)
            .accessibilityHint(hasLocation ? "Show on map" : "")

            Spacer()

            if let source = appState.transportSource(for: member.id), !isMe {
                Image(systemName: source.icon)
                    .font(.caption2)
                    .foregroundStyle(source.tint)
                    .accessibilityLabel(source.accessibilityLabel)
            }
            PresenceBadge(status: status)

            if hasLocation && !isMe {
                Button {
                    compassMember = member
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(memberColor)
                        .background(memberColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Find \(member.displayName)")
            }
        }
        .accessibilityElement(children: .contain)
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

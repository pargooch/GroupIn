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
                Text("They'll lose access to this group. They can rejoin if they still have the invite code.")
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
            mapSection(group: group, cameraBinding: $vm.cameraPosition)
            if showsLocationStatus {
                Section { locationStatusContent }
            }
            expirySection(group: group)
            groupSection(group: group)
            membersSection(group: group)
            messagesSection
            safetySection
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
    private func mapSection(group: GroupSession,
                            cameraBinding: Binding<MapCameraPosition>) -> some View {
        Section {
            ZStack(alignment: .bottomTrailing) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    mapContent(group: group,
                               cameraBinding: cameraBinding,
                               now: context.date)
                }
                fitAllButton
                    .padding(10)
            }
            .overlay(alignment: .topLeading) {
                connectionModePill
                    .padding(10)
            }
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityLabel("Map showing your location and group members")
        }
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
            viewModel.fitAllMembers()
        } label: {
            Image(systemName: "scope")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(.thickMaterial, in: Circle())
        }
        .accessibilityLabel("Fit all members on map")
    }

    @ViewBuilder
    private func membersSection(group: GroupSession) -> some View {
        Section("Members (\(group.members.count))") {
            if group.members.isEmpty {
                Text("No members yet").foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 0) {
                        ForEach(group.members) { member in
                            memberRow(member, group: group, now: context.date)
                                .padding(.vertical, 4)
                            if member.id != group.members.last?.id {
                                Divider()
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
                // "Done" — closes this dashboard and returns home. The
                // user stays a member of the group; sharing keeps
                // running in the background. Removing yourself from
                // the group entirely is a separate swipe-delete action
                // on the Home screen's group list.
                Button("Done") {
                    appState.leaveGroup()
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

    // MARK: - Map

    @ViewBuilder
    private func mapContent(group: GroupSession,
                            cameraBinding: Binding<MapCameraPosition>,
                            now: Date) -> some View {
        Map(position: cameraBinding) {
            ForEach(group.members) { member in
                if let coord = member.coordinate {
                    let status = PresenceStatus(
                        lastSeen: member.lastSeen,
                        hasFix: true,
                        now: now
                    )
                    Annotation(member.displayName, coordinate: coord.clLocation) {
                        memberMapPin(member: member, status: status)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memberMapPin(member: User, status: PresenceStatus) -> some View {
        let isFocused = viewModel.focusedMemberID == member.id
        let color = Color.memberColor(for: member.id)

        ZStack {
            // Direction indicator (Google Maps style) — only when the
            // device has a valid heading. Two layers: a wider faint halo
            // and a focused brighter beam, both with a radial gradient
            // so the apex (where the person is) is solid and the outer
            // edge fades away. Blur softens the pie-slice edges.
            if let heading = member.heading {
                ZStack {
                    DirectionCone(spreadDegrees: 90)
                        .fill(RadialGradient(
                            colors: [color.opacity(0.30), color.opacity(0.0)],
                            center: .center,
                            startRadius: 8,
                            endRadius: 50
                        ))
                        .blur(radius: 4)
                    DirectionCone(spreadDegrees: 50)
                        .fill(RadialGradient(
                            colors: [color.opacity(0.65), color.opacity(0.0)],
                            center: .center,
                            startRadius: 6,
                            endRadius: 44
                        ))
                        .blur(radius: 1.5)
                }
                .frame(width: 100, height: 100)
                .rotationEffect(.degrees(heading))
                .animation(.smooth(duration: 0.3), value: heading)
            }
            if isFocused {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                    .frame(width: 56, height: 56)
                    .transition(.scale.combined(with: .opacity))
            }
            Circle()
                .fill(color)
                .frame(width: 38, height: 38)
            AvatarView(data: member.avatarData,
                       name: member.displayName,
                       size: 32,
                       tint: color)
        }
        .opacity(status.mapOpacity)
        .animation(.smooth, value: isFocused)
        .accessibilityLabel("\(member.displayName), \(status.label)")
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
        // Owner-only: long-press a non-self, non-owner member to open
        // a context menu offering removal. Confirmation alert is
        // wired one level up via `memberToRemove`.
        .contextMenu {
            if viewModel.isOwner && !isMe && member.id != group.ownerID {
                Button(role: .destructive) {
                    memberToRemove = member
                } label: {
                    Label("Remove from group", systemImage: "person.fill.xmark")
                }
            }
        }
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

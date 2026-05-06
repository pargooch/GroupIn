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
    @State private var viewModel: GroupDashboardViewModel
    @State private var didCopyInviteCode = false

    init(viewModel: GroupDashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            .toolbar { dashboardToolbar }
            .modifier(DashboardModifiers(viewModel: viewModel))
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
        }
    }

    /// Only show the "Your location" section when the user needs to act on
    /// permission (denied/restricted) or hasn't granted yet. Authorized +
    /// having a fix is the silent happy path — the map shows it.
    private var showsLocationStatus: Bool {
        switch appState.locationAuthorizationStatus {
        case .denied, .restricted, .notDetermined:
            return true
        case .authorizedWhenInUse, .authorizedAlways:
            return viewModel.currentUser.coordinate == nil
        @unknown default:
            return true
        }
    }

    @ViewBuilder
    private func groupSection(group: GroupSession) -> some View {
        Section("Group") {
            LabeledContent("Name", value: group.name)
            inviteCodeButton(code: group.inviteCode)
        }
    }

    @ViewBuilder
    private func inviteCodeButton(code: String) -> some View {
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
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityLabel("Map showing your location and group members")
        }
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
                Button("Leave", role: .destructive) {
                    appState.leaveGroup()
                }
                .accessibilityHint("Leaves this group view and returns home")
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
            HStack(spacing: 8) {
                ProgressView()
                Text("Acquiring location…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

        @unknown default:
            Text("Unknown location authorization state.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

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

        Button {
            viewModel.focus(on: member)
        } label: {
            HStack(spacing: 12) {
                AvatarView(data: member.avatarData,
                           name: member.displayName,
                           size: 40,
                           tint: Color.memberColor(for: member.id))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if member.id == viewModel.currentUser.id {
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
                Spacer()
                PresenceBadge(status: status)
                if hasLocation {
                    Image(systemName: "location.magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasLocation)
        .accessibilityHint(hasLocation ? "Show on map" : "")
        .accessibilityElement(children: .combine)
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

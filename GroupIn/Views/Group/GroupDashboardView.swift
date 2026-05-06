//
//  GroupDashboardView.swift
//  GroupIn
//

import SwiftUI
import MapKit
import CoreLocation

struct GroupDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: GroupDashboardViewModel

    init(viewModel: GroupDashboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if let group = viewModel.group {
                List {
                    expirySection(group: group)

                    Section("Group") {
                        LabeledContent("Name", value: group.name)
                        LabeledContent("Invite Code", value: group.inviteCode)
                            .textSelection(.enabled)
                    }

                    Section("Your location") {
                        locationStatusContent
                    }

                    Section("Map") {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            mapContent(group: group,
                                       cameraBinding: $vm.cameraPosition,
                                       now: context.date)
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Map showing your location and group members")
                    }

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
        .toolbar {
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
        .sheet(isPresented: $vm.showExtendSheet) {
            if let group = viewModel.group {
                ExtendGroupSheet(currentExpiresAt: group.expiresAt) { newDate in
                    await viewModel.proposeExtension(newExpiresAt: newDate)
                }
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.currentUser.coordinate) { _, newCoord in
            if let coord = newCoord {
                viewModel.centerCameraIfNeeded(coord)
            }
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
            if let coord = viewModel.currentUser.coordinate {
                LabeledContent("Latitude",
                               value: String(format: "%.5f", coord.latitude))
                LabeledContent("Longitude",
                               value: String(format: "%.5f", coord.longitude))
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
        ZStack {
            Circle()
                .fill(member.id == viewModel.currentUser.id ? Color.blue : Color.green)
                .frame(width: 36, height: 36)
            AvatarView(data: member.avatarData,
                       name: member.displayName,
                       size: 30)
        }
        .opacity(status.mapOpacity)
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
        HStack(spacing: 12) {
            AvatarView(data: member.avatarData,
                       name: member.displayName,
                       size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.body.weight(.medium))
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
                if let coord = member.coordinate {
                    Text(String(format: "%.4f, %.4f", coord.latitude, coord.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No location yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PresenceBadge(status: status)
        }
        .accessibilityElement(children: .combine)
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

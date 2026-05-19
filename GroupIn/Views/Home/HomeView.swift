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
        List {
            statusSection

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

            createJoinSection

            Section {
                if appState.myGroups.isEmpty {
                    emptyGroupsState
                } else {
                    ForEach(appState.myGroups) { group in
                        let isOwner = group.ownerID == appState.currentUser.id
                        Button {
                            appState.open(group: group)
                        } label: {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens group \(group.name)")
                        // Per-row swipe label: owners delete the whole
                        // group (cascade removes members server-side);
                        // non-owners leave (their member record alone
                        // is removed, others stay intact). Wording
                        // matches the verb that actually happens.
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
                }
            } header: {
                Text("Your groups")
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

    @ViewBuilder
    private var statusSection: some View {
        let banners = statusBanners
        if !banners.isEmpty {
            Section {
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
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Status")
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

    @ViewBuilder
    private var emptyGroupsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 52, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.cyan, .pink, .green)
                .shadow(color: .cyan.opacity(0.7), radius: 7)
                .shadow(color: .pink.opacity(0.6), radius: 11)
                .accessibilityHidden(true)

            Text("No groups yet")
                .font(.headline)

            Text("Create one or join with a code to start finding your friends in real time — online or off.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No groups yet. Create one or join with a code.")
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

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                Text("Code \(group.inviteCode) · \(group.members.count) member\(group.members.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                expiryLine(group: group)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.category.label) group \(group.name)")
    }

    @ViewBuilder
    private func expiryLine(group: GroupSession) -> some View {
        HStack(spacing: 4) {
            Image(systemName: group.hasPendingExtension ? "clock.arrow.circlepath" : "clock")
                .font(.caption2)
            Text("Expires \(group.expiresAt, style: .relative)")
                .font(.caption2)
            if group.hasPendingExtension {
                Text("· extension pending")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(group.expiresAt.timeIntervalSinceNow < 30 * 60 ? .orange : .secondary)
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

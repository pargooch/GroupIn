//
//  HomeView.swift
//  GroupIn
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section {
                Button {
                    appState.path.append(.profileEditor)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(data: appState.localProfile.avatarData,
                                   name: appState.localProfile.displayName,
                                   size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.localProfile.displayName)
                                .font(.headline)
                            Text("Edit profile")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                .accessibilityHint("Opens your profile to edit name and photo")
            }

            Section {
                if appState.myGroups.isEmpty {
                    Text("You haven't joined any groups yet. Create one or join with a code.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.myGroups) { group in
                        Button {
                            appState.open(group: group)
                        } label: {
                            groupRow(group)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens group \(group.name)")
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            appState.remove(group: appState.myGroups[index])
                        }
                    }
                }
            } header: {
                Text("Your groups")
            }

            Section {
                Button {
                    appState.path.append(.createGroup)
                } label: {
                    Label("Create a Group", systemImage: "plus.circle.fill")
                }
                .accessibilityHint("Starts a new group you can invite others to")

                Button {
                    appState.path.append(.joinGroup)
                } label: {
                    Label("Join a Group", systemImage: "person.badge.plus")
                }
                .accessibilityHint("Join an existing group with an invite code")
            }
        }
        .navigationTitle("GroupIn")
        .navigationBarTitleDisplayMode(.inline)
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

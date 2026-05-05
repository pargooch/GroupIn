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
        HStack {
            Image(systemName: "person.3.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                Text("Code \(group.inviteCode) · \(group.members.count) member\(group.members.count == 1 ? "" : "s")")
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
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty") {
    NavigationStack { HomeView() }
        .environment(AppState())
}

#Preview("With groups") {
    let state = AppState()
    state.myGroups = [
        GroupSession(name: "Weekend Hike", inviteCode: "ABC234",
                     members: [User(displayName: "Me")]),
        GroupSession(name: "Office", inviteCode: "ZX9KQM",
                     members: [User(displayName: "Me"), User(displayName: "Alex")])
    ]
    return NavigationStack { HomeView() }
        .environment(state)
}

//
//  GroupDashboardView.swift
//  GroupIn
//

import SwiftUI
import MapKit

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
                    Section("Group") {
                        LabeledContent("Name", value: group.name)
                        LabeledContent("Invite Code", value: group.inviteCode)
                            .textSelection(.enabled)
                    }

                    Section("Your location") {
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
                    }

                    Section("Map") {
                        Map(position: $vm.cameraPosition) {
                            if let me = viewModel.currentUser.coordinate {
                                Marker(viewModel.currentUser.displayName,
                                       systemImage: "person.fill",
                                       coordinate: me.clLocation)
                                    .tint(.blue)
                            }
                            ForEach(otherMembersWithCoordinates(in: group)) { member in
                                if let coord = member.coordinate {
                                    Marker(member.displayName,
                                           systemImage: "person.fill",
                                           coordinate: coord.clLocation)
                                        .tint(.green)
                                }
                            }
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Map showing your location and group members")
                    }

                    Section("Members (\(group.members.count))") {
                        if group.members.isEmpty {
                            Text("No members yet").foregroundStyle(.secondary)
                        } else {
                            ForEach(group.members) { member in
                                memberRow(member)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Leave", role: .destructive) {
                        appState.leaveGroup()
                    }
                    .accessibilityHint("Leaves this group view and returns home")
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
    }

    private func otherMembersWithCoordinates(in group: GroupSession) -> [User] {
        group.members.filter { $0.id != viewModel.currentUser.id && $0.coordinate != nil }
    }

    @ViewBuilder
    private func memberRow(_ member: User) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .foregroundStyle(member.id == viewModel.currentUser.id ? .blue : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(member.displayName)
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
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let state = AppState()
    state.currentGroup = GroupSession(
        name: "Weekend Hike",
        inviteCode: "ABC234",
        members: [User(displayName: "Me")]
    )
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

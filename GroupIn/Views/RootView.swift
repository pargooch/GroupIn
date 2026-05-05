//
//  RootView.swift
//  GroupIn
//
//  Top-level NavigationStack. Routes are driven by AppState.path.
//  ViewModels are constructed here at navigation time and injected
//  into their views — keeps the AppState environment clean and makes
//  testing each VM in isolation straightforward.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationStack(path: $appState.path) {
            HomeView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .createGroup:
                        CreateGroupView(
                            viewModel: CreateGroupViewModel(appState: appState)
                        )
                    case .joinGroup:
                        JoinGroupView(
                            viewModel: JoinGroupViewModel(appState: appState)
                        )
                    case .groupDashboard(let groupID):
                        GroupDashboardView(
                            viewModel: GroupDashboardViewModel(
                                appState: appState,
                                groupID: groupID
                            )
                        )
                    }
                }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}

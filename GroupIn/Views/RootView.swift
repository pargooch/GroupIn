//
//  RootView.swift
//  GroupIn
//
//  Top-level switch: onboarding gate vs. main NavigationStack. Routes
//  inside the main stack are driven by AppState.path. ViewModels are
//  constructed at navigation time and injected into their views.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.localProfile.needsOnboarding {
            OnboardingView()
        } else {
            MainStack()
        }
    }
}

private struct MainStack: View {
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
                    case .profileEditor:
                        ProfileEditorView()
                    }
                }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}

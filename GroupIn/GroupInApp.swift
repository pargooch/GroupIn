//
//  GroupInApp.swift
//  GroupIn
//
//  Created by Novin dokht Elmi on 05/05/26.
//

import SwiftUI

@main
struct GroupInApp: App {
    /// Flip to `true` once you've enabled the iCloud capability + CloudKit
    /// in Xcode (Target → Signing & Capabilities → + Capability → iCloud).
    /// Calling `CKContainer.default()` without that entitlement crashes
    /// at launch from inside the CloudKit framework.
    private static let useCloudKit = true

    /// Owns UIApplicationDelegate methods we need for CloudKit silent
    /// pushes (CKQuerySubscription delivers via APNs). Without this,
    /// AppState falls back to its 10-second polling refresh.
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    @State private var appState: AppState = {
        if Self.useCloudKit {
            return AppState(groupService: CloudKitService())
        } else {
            return AppState() // LocalGroupService default
        }
    }()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Foreground = seeker (full stack). Background/inactive =
            // sought (BLE peripheral keeps advertising, transport
            // sleeps). See `AppState.applyScenePhase(active:)`.
            appState.applyScenePhase(active: newPhase == .active)
        }
    }
}

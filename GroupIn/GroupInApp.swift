//
//  GroupInApp.swift
//  GroupIn
//
//  Created by Novin dokht Elmi on 05/05/26.
//

import SwiftUI

@main
struct GroupInApp: App {
    /// Master switch for CloudKit. When false, the app runs **fully
    /// offline**: LocalGroupService backs every CloudKitServicing call,
    /// AppDelegate silent-push hooks short-circuit, and AppState skips
    /// CKAccountChanged listening. Joins must happen over BLE
    /// (JoinRequest / JoinResponse on the in-range members' GATT).
    /// Flip back to `true` once you've re-enabled the iCloud capability
    /// in Xcode (Target → Signing & Capabilities → + Capability → iCloud);
    /// every CloudKit call site is unchanged and will resume automatically.
    static let useCloudKit = false

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

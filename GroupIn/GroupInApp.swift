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

    @State private var appState: AppState = {
        if Self.useCloudKit {
            return AppState(groupService: CloudKitService())
        } else {
            return AppState() // LocalGroupService default
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

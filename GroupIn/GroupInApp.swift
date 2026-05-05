//
//  GroupInApp.swift
//  GroupIn
//
//  Created by Novin dokht Elmi on 05/05/26.
//

import SwiftUI

@main
struct GroupInApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

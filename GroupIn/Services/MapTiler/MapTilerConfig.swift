//
//  MapTilerConfig.swift
//  GroupIn
//
//  Configuration for the MapLibre-rendered MapTiler map. We render
//  vector tiles via MapLibre Native (not MKMapView), so this file
//  only needs to hand the style URL to the map view at setup.
//
//  Key safety: MapTiler keys live in the app bundle (they're not
//  server secrets), but you should still scope yours in the MapTiler
//  dashboard to your bundle ID so a leaked IPA can't burn your quota.
//

import SwiftUI

enum MapTilerConfig {
    /// MapTiler API key. Get one at https://maptiler.com/cloud/.
    /// Lock it to the GroupIn bundle ID in the MapTiler dashboard.
    static let apiKey: String = "byBBed0Bu0KkVlxOcMVg"

    /// Custom MapTiler style IDs (the UUIDs from the style editor URL),
    /// one per appearance. Swap these when forking the styles for
    /// design tweaks.
    static let lightStyleID: String = "019e1c8e-17f0-7b17-a0ea-80ae1819162d"
    static let darkStyleID: String = "019e282a-364f-7c20-91d9-08d843064870"

    /// True once `apiKey` is non-empty. Callers decide whether to
    /// install the MapLibre map or fall back to a placeholder.
    static var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fully-qualified style.json URL for the given appearance — the
    /// map view loads this at init and re-loads it when the system
    /// switches between light and dark mode.
    static func styleURL(for colorScheme: ColorScheme) -> URL? {
        guard isConfigured else { return nil }
        let id = colorScheme == .dark ? darkStyleID : lightStyleID
        return URL(string: "https://api.maptiler.com/maps/\(id)/style.json?key=\(apiKey)")
    }
}

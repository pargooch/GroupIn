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

import Foundation

enum MapTilerConfig {
    /// MapTiler API key. Get one at https://maptiler.com/cloud/.
    /// Lock it to the GroupIn bundle ID in the MapTiler dashboard.
    static let apiKey: String = "byBBed0Bu0KkVlxOcMVg"

    /// Custom MapTiler style ID (the UUID from the style editor URL).
    /// Swap this when forking the style for design tweaks.
    static let styleID: String = "019e1c8e-17f0-7b17-a0ea-80ae1819162d"

    /// True once `apiKey` is non-empty. Callers decide whether to
    /// install the MapLibre map or fall back to a placeholder.
    static var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fully-qualified style.json URL that MapLibre loads at init.
    static var styleURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "https://api.maptiler.com/maps/\(styleID)/style.json?key=\(apiKey)")
    }
}

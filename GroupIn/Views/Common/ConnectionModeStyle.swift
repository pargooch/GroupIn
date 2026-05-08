//
//  ConnectionModeStyle.swift
//  GroupIn
//
//  UI affordances for the connection-mode pill — kept separate from the
//  enum's domain definition so AppState stays UI-agnostic.
//

import SwiftUI

extension ConnectionMode {
    var icon: String {
        switch self {
        case .onlineWithPeers: return "antenna.radiowaves.left.and.right.circle.fill"
        case .online:          return "icloud.fill"
        case .peersOnly:       return "antenna.radiowaves.left.and.right"
        case .offline:         return "wifi.slash"
        }
    }

    var label: String {
        switch self {
        case .onlineWithPeers: return "Online + Nearby"
        case .online:          return "Online"
        case .peersOnly:       return "Nearby only"
        case .offline:         return "No connection"
        }
    }

    var tint: Color {
        switch self {
        case .onlineWithPeers: return .green
        case .online:          return .blue
        case .peersOnly:       return .orange
        case .offline:         return .red
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .onlineWithPeers: return "Online and connected to nearby members"
        case .online:          return "Online"
        case .peersOnly:       return "No internet — connected to nearby members via Bluetooth"
        case .offline:         return "No internet and no nearby members"
        }
    }
}

extension TransportSource {
    var icon: String {
        switch self {
        case .cloud: return "icloud"
        case .ble:   return "antenna.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .cloud: return .blue
        case .ble:   return .green
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .cloud: return "via the cloud"
        case .ble:   return "via Bluetooth"
        }
    }
}

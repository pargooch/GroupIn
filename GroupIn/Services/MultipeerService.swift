//
//  MultipeerService.swift
//  GroupIn
//
//  Protocol stub — Multipeer Connectivity fallback arrives in a later step.
//

import Foundation
import MultipeerConnectivity

protocol MultipeerServicing {
    func startHosting(displayName: String)
    func startBrowsing(displayName: String)
    func stop()
}

final class MultipeerService: MultipeerServicing {
    func startHosting(displayName: String) {}
    func startBrowsing(displayName: String) {}
    func stop() {}
}

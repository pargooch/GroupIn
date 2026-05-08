//
//  NetworkMonitor.swift
//  GroupIn
//
//  Thin wrapper around NWPathMonitor that surfaces a simple `isOnline`
//  callback on the main actor. AppState reads it for the connection-mode
//  badge and to gate cloud-only behaviors.
//

import Foundation
import Network

@MainActor
final class NetworkMonitor {
    private let monitor: NWPathMonitor

    private(set) var isOnline: Bool = true

    /// Fires on every change after start, on the main actor.
    var onChange: (@MainActor (Bool) -> Void)?

    init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isOnline != satisfied else { return }
                self.isOnline = satisfied
                self.onChange?(satisfied)
            }
        }
        let queue = DispatchQueue(label: "com.NDE.GroupIn.networkmonitor",
                                   qos: .utility)
        self.monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

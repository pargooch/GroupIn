//
//  BeaconMonitorService.swift
//  GroupIn
//
//  Wraps a dedicated CLLocationManager that monitors a single iBeacon
//  region. iOS keeps the registration alive across app relaunches and
//  even from a force-quit state — when a matching beacon enters range,
//  iOS launches the app for ~10 seconds, our delegate fires, and we
//  emit a tickle notification telling the user to open GroupIn.
//
//  Requires "always" authorization. The first call to `start()` triggers
//  the always-prompt; without it, region events only fire while the app
//  is foregrounded and the whole feature collapses.
//

import Foundation
import CoreLocation

@MainActor
final class BeaconMonitorService: NSObject {
    static let regionIdentifier = "com.NDE.GroupIn.peers"

    private let manager: CLLocationManager
    private let region: CLBeaconRegion

    /// Fires whenever iOS reports we just entered the region. The
    /// callback runs on MainActor; AppState wires it into the
    /// notification path.
    var onEnter: (@MainActor () -> Void)?

    override init() {
        self.manager = CLLocationManager()
        self.region = CLBeaconRegion(
            uuid: BLEAdvertisementService.iBeaconUUID,
            identifier: Self.regionIdentifier
        )
        self.region.notifyOnEntry = true
        self.region.notifyOnExit = false
        self.region.notifyEntryStateOnDisplay = true
        super.init()
        self.manager.delegate = self
    }

    func start() {
        // Always-auth is required for background region events. Calling
        // this is idempotent — iOS will only show the prompt once.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        } else if manager.authorizationStatus == .notDetermined {
            // The app's primary location flow already requested
            // when-in-use earlier. We escalate when the user is in a
            // group context.
            manager.requestAlwaysAuthorization()
        }

        guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
            return
        }
        manager.startMonitoring(for: region)
    }

    func stop() {
        manager.stopMonitoring(for: region)
    }
}

extension BeaconMonitorService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionIdentifier else { return }
        Task { @MainActor [weak self] in
            self?.onEnter?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        // Silently ignore. Most common cause is a transient state during
        // launch; iOS retries on its own.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // If the user upgraded from when-in-use to always after the
        // initial start() call, retry the registration.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if manager.authorizationStatus == .authorizedAlways {
                self.manager.startMonitoring(for: self.region)
            }
        }
    }
}

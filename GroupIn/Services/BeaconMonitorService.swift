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
//  On entry we briefly range beacons against the same UUID so we can pull
//  the major (group) and minor (member) values out of the advertisements.
//  That's how AppState turns "someone from your group is nearby" into
//  "Kian is nearby."
//

import Foundation
import CoreLocation

@MainActor
final class BeaconMonitorService: NSObject {
    nonisolated static let regionIdentifier = "com.NDE.GroupIn.peers"

    private let manager: CLLocationManager
    private let region: CLBeaconRegion
    private let constraint: CLBeaconIdentityConstraint

    /// Caps the ranging window after region entry. iOS only gives us
    /// ~10 s of background time on entry, so we sample for a couple of
    /// seconds and then hand off to the notification path.
    private static let rangingWindow: TimeInterval = 3
    private var rangingStopTask: Task<Void, Never>?
    private var collectedBeacons: [CLBeacon] = []

    /// Fires whenever iOS reports we just entered the region. The
    /// callback runs on MainActor; AppState wires it into the
    /// notification path. The `[CLBeacon]` payload is the result of a
    /// short ranging window — empty if the device went out of range
    /// before we could sample, or if ranging isn't available.
    var onEnter: (@MainActor ([CLBeacon]) -> Void)?

    override init() {
        self.manager = CLLocationManager()
        self.region = CLBeaconRegion(
            uuid: BLEAdvertisementService.iBeaconUUID,
            identifier: Self.regionIdentifier
        )
        self.constraint = CLBeaconIdentityConstraint(
            uuid: BLEAdvertisementService.iBeaconUUID
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
        manager.stopRangingBeacons(satisfying: constraint)
        rangingStopTask?.cancel()
        rangingStopTask = nil
        collectedBeacons.removeAll()
    }

    private func beginRangingForEntry() {
        guard CLLocationManager.isRangingAvailable() else {
            // No ranging — fire the callback immediately with no beacon
            // info so the user still gets a generic group nudge.
            onEnter?([])
            return
        }
        collectedBeacons.removeAll()
        manager.startRangingBeacons(satisfying: constraint)

        rangingStopTask?.cancel()
        rangingStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.rangingWindow))
            guard let self, !Task.isCancelled else { return }
            self.finishRanging()
        }
    }

    private func finishRanging() {
        manager.stopRangingBeacons(satisfying: constraint)
        let beacons = collectedBeacons
        collectedBeacons.removeAll()
        rangingStopTask = nil
        onEnter?(beacons)
    }
}

extension BeaconMonitorService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionIdentifier else { return }
        Task { @MainActor [weak self] in
            self?.beginRangingForEntry()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didRangeBeacons beacons: [CLBeacon],
                                     in region: CLBeaconRegion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep a rolling sample. CoreLocation streams ranging
            // callbacks roughly once a second; we union by minor so we
            // see every distinct member that came into range during the
            // window (rather than just whoever happened to be in the
            // last batch).
            for beacon in beacons {
                if !self.collectedBeacons.contains(where: {
                    $0.minor == beacon.minor && $0.major == beacon.major
                }) {
                    self.collectedBeacons.append(beacon)
                }
            }
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

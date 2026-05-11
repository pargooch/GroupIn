//
//  LocationService.swift
//  GroupIn
//
//  Concrete Core Location implementation. Publishes coordinate, heading,
//  and authorization updates via async streams so consumers (AppState)
//  can iterate them as pure async sequences — no closure plumbing.
//

import Foundation
import CoreLocation

/// One GPS fix carrying everything Path B needs to record provenance:
/// not just the latitude/longitude but how confident CoreLocation was
/// in the reading and exactly when it was taken. Replaces the old
/// "stream of bare Coordinates" — consumers can no longer accidentally
/// lose track of accuracy by treating two fixes as equivalent.
struct LocationFix: Sendable {
    let coordinate: Coordinate
    /// Horizontal accuracy in meters (1-sigma). Mirrors
    /// `CLLocation.horizontalAccuracy`. Always > 0 when the fix is
    /// valid; CoreLocation uses negative values to signal an invalid
    /// reading and we filter those out before yielding.
    let accuracy: Double
    let timestamp: Date
}

@MainActor
protocol LocationServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationUpdates: AsyncStream<LocationFix> { get }
    var headingUpdates: AsyncStream<Double> { get }
    var authorizationUpdates: AsyncStream<CLAuthorizationStatus> { get }
    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
    /// Adaptive battery hook. AppState calls this in response to motion
    /// classification: when the user has been stationary, drop accuracy
    /// to ~100m to ease the GPS chip's duty cycle; when they're moving
    /// again, ramp back to best.
    func adjustForMotion(stationary: Bool)
}

@MainActor
final class LocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager: CLLocationManager

    let locationUpdates: AsyncStream<LocationFix>
    let headingUpdates: AsyncStream<Double>
    let authorizationUpdates: AsyncStream<CLAuthorizationStatus>

    private nonisolated let locationContinuation: AsyncStream<LocationFix>.Continuation
    private nonisolated let headingContinuation: AsyncStream<Double>.Continuation
    private nonisolated let authContinuation: AsyncStream<CLAuthorizationStatus>.Continuation

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        let (locStream, locCont) = AsyncStream.makeStream(of: LocationFix.self)
        let (hdgStream, hdgCont) = AsyncStream.makeStream(of: Double.self)
        let (authStream, authCont) = AsyncStream.makeStream(of: CLAuthorizationStatus.self)
        self.locationUpdates = locStream
        self.headingUpdates = hdgStream
        self.authorizationUpdates = authStream
        self.locationContinuation = locCont
        self.headingContinuation = hdgCont
        self.authContinuation = authCont
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // Best accuracy with no distance filter — every meaningful sample
        // is delivered. Battery-heavy; revisit with adaptive throttling later.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // Heading filter: deliver updates on every ≥1° change. Combined
        // with our 5-sample circular smoothing in AppState, this gives a
        // fluid arrow that tracks phone rotation smoothly without
        // chasing magnetometer noise.
        manager.headingFilter = 1

        // Background sharing: with whenInUse + UIBackgroundModes=location,
        // location keeps flowing while the app is backgrounded or the
        // phone is locked. We guard `allowsBackgroundLocationUpdates`
        // because setting it without the matching Info.plist entry is a
        // hard assertion crash on Apple's side. Pause-disable + the
        // visible indicator are safe to set unconditionally.
        if Self.bundleSupportsBackgroundLocation() {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Reads the running app bundle's `UIBackgroundModes` to verify
    /// `"location"` is actually present before we try to opt into
    /// `allowsBackgroundLocationUpdates`. Without this guard, a missing
    /// or out-of-sync Info.plist key crashes the app on launch.
    private static func bundleSupportsBackgroundLocation() -> Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func adjustForMotion(stationary: Bool) {
        // Distance filter stays at None so we still receive heartbeat
        // fixes — they let the "Sharing live" indicator stay green and
        // keep the freshness window honest. Only the accuracy budget
        // shifts. Apple's GPS hardware uses much less power at lower
        // accuracy targets.
        manager.desiredAccuracy = stationary
            ? kCLLocationAccuracyHundredMeters
            : kCLLocationAccuracyBest
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        // CoreLocation reports negative `horizontalAccuracy` for
        // invalid fixes. Filter those out — a bad fix with bogus
        // accuracy is worse than no fix at all, because it'd be
        // recorded with provenance = .gps and treated as truth.
        guard last.horizontalAccuracy > 0 else { return }
        let coord = Coordinate(latitude: last.coordinate.latitude,
                               longitude: last.coordinate.longitude)
        let fix = LocationFix(
            coordinate: coord,
            accuracy: last.horizontalAccuracy,
            timestamp: last.timestamp
        )
        locationContinuation.yield(fix)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy = totally invalid. Above ~35° = calibration
        // poor or strong magnetic interference; the bearing is unreliable
        // enough that no cone is better than a wrong cone.
        guard newHeading.headingAccuracy >= 0,
              newHeading.headingAccuracy < 35 else { return }
        headingContinuation.yield(newHeading.trueHeading)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Swallowed for now. Hook a logger here when one exists.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authContinuation.yield(status)
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.manager.startUpdatingLocation()
                if CLLocationManager.headingAvailable() {
                    self.manager.startUpdatingHeading()
                }
            default:
                break
            }
        }
    }
}

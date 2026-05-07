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

@MainActor
protocol LocationServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationUpdates: AsyncStream<Coordinate> { get }
    var headingUpdates: AsyncStream<Double> { get }
    var authorizationUpdates: AsyncStream<CLAuthorizationStatus> { get }
    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
}

@MainActor
final class LocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager: CLLocationManager

    let locationUpdates: AsyncStream<Coordinate>
    let headingUpdates: AsyncStream<Double>
    let authorizationUpdates: AsyncStream<CLAuthorizationStatus>

    private nonisolated let locationContinuation: AsyncStream<Coordinate>.Continuation
    private nonisolated let headingContinuation: AsyncStream<Double>.Continuation
    private nonisolated let authContinuation: AsyncStream<CLAuthorizationStatus>.Continuation

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        let (locStream, locCont) = AsyncStream.makeStream(of: Coordinate.self)
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
        // Heading filter: only deliver updates when bearing changes by
        // ≥3°. Avoids flooding the stream while the device is held still
        // (where magnetometer noise causes constant micro-fluctuations).
        manager.headingFilter = 3
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

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coord = Coordinate(latitude: last.coordinate.latitude,
                               longitude: last.coordinate.longitude)
        locationContinuation.yield(coord)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy = invalid (no calibration, nearby magnetic
        // interference, etc.). Skip — better to show no cone than the
        // wrong direction.
        guard newHeading.headingAccuracy >= 0 else { return }
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

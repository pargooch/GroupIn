//
//  LocationService.swift
//  GroupIn
//
//  Concrete Core Location implementation. Publishes coordinate updates
//  AND authorization changes via async streams so consumers (AppState)
//  can iterate them as pure async sequences — no closure plumbing.
//

import Foundation
import CoreLocation

@MainActor
protocol LocationServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationUpdates: AsyncStream<Coordinate> { get }
    var authorizationUpdates: AsyncStream<CLAuthorizationStatus> { get }
    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
}

@MainActor
final class LocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager: CLLocationManager

    let locationUpdates: AsyncStream<Coordinate>
    let authorizationUpdates: AsyncStream<CLAuthorizationStatus>

    private nonisolated let locationContinuation: AsyncStream<Coordinate>.Continuation
    private nonisolated let authContinuation: AsyncStream<CLAuthorizationStatus>.Continuation

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        let (locStream, locCont) = AsyncStream.makeStream(of: Coordinate.self)
        let (authStream, authCont) = AsyncStream.makeStream(of: CLAuthorizationStatus.self)
        self.locationUpdates = locStream
        self.authorizationUpdates = authStream
        self.locationContinuation = locCont
        self.authContinuation = authCont
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // Best accuracy with no distance filter — every meaningful sample
        // is delivered. Battery-heavy; revisit with adaptive throttling later.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        manager.startUpdatingLocation()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
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
            default:
                break
            }
        }
    }
}

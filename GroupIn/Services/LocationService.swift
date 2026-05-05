//
//  LocationService.swift
//  GroupIn
//
//  Concrete Core Location implementation. Publishes coordinate updates
//  via an AsyncStream so consumers (AppState) can iterate them as a
//  pure async sequence — no closure plumbing or KVO.
//

import Foundation
import CoreLocation

@MainActor
protocol LocationServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var locationUpdates: AsyncStream<Coordinate> { get }
    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
}

@MainActor
final class LocationService: NSObject, LocationServicing, CLLocationManagerDelegate {
    private let manager: CLLocationManager

    /// Single shared stream — created once at init.
    /// AsyncStream is single-consumer; AppState owns the only iterator.
    let locationUpdates: AsyncStream<Coordinate>
    private nonisolated let continuation: AsyncStream<Coordinate>.Continuation

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Coordinate.self)
        self.locationUpdates = stream
        self.continuation = continuation
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25 // meters
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
    //
    // Marked `nonisolated` because CLLocationManagerDelegate isn't
    // MainActor-isolated. Continuation is Sendable so we can yield from
    // the delegate's queue safely; for anything that touches our own
    // MainActor state we hop with a Task.

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coord = Coordinate(latitude: last.coordinate.latitude,
                               longitude: last.coordinate.longitude)
        continuation.yield(coord)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Swallowed for now. Hook a logger here when one exists.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
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

//
//  HealthKitService.swift
//  GroupIn
//
//  Read-only HealthKit access for the debug telemetry panel: today's
//  cumulative step count + walking/running distance. Distinct from the
//  live CMPedometer session counter — HealthKit aggregates across all
//  the user's devices (iPhone + Watch) and the whole day, so comparing
//  the two side by side helps sanity-check our own step/stride pipeline.
//
//  Entirely best-effort. If the HealthKit entitlement isn't present,
//  the device doesn't support HealthKit, or the user declines the
//  permission, every value stays nil and the panel shows "unavailable"
//  — nothing crashes, nothing blocks. Enable the capability
//  (HealthKit + NSHealthShareUsageDescription) to get real numbers.
//

import Foundation
import HealthKit

@MainActor
@Observable
final class HealthKitService {

    /// Today's cumulative step count, or nil when unavailable / not
    /// yet loaded / permission denied.
    private(set) var todaySteps: Int?
    /// Today's cumulative walking + running distance in metres.
    private(set) var todayMeters: Double?
    /// Human-readable status for the debug panel.
    private(set) var status: String = "not started"

    private let store = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    private var started = false

    private let stepType = HKQuantityType(.stepCount)
    private let distanceType = HKQuantityType(.distanceWalkingRunning)

    /// Request read authorization and begin observing. Idempotent.
    /// Safe to call even without the entitlement — it just lands in
    /// the failure branch and sets `status`.
    func start() {
        guard !started else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "unavailable on device"
            return
        }
        // Requesting read authorization without `NSHealthShareUsageDescription`
        // in the bundle is a HARD CRASH per Apple's API contract — not a
        // graceful error. Until the HealthKit capability + usage
        // description are configured, this key is absent, so guard on it.
        // The moment it's added, HealthKit self-enables with no code change.
        // (This guard is what was crash-looping the app at launch: the
        // restored group reactivated BLE presence → start() → requestAuthorization
        // → crash → relaunch → repeat.)
        guard Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") != nil else {
            status = "disabled (enable HealthKit capability + usage description)"
            return
        }
        started = true
        status = "requesting authorization…"

        let types: Set<HKObjectType> = [stepType, distanceType]
        store.requestAuthorization(toShare: [], read: types) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = "auth error: \(error.localizedDescription)"
                    return
                }
                guard granted else {
                    self.status = "permission denied"
                    return
                }
                self.status = "authorized"
                self.beginObserving()
                self.refresh()
            }
        }
    }

    func stop() {
        for q in observerQueries { store.stop(q) }
        observerQueries.removeAll()
        started = false
        status = "stopped"
    }

    /// Re-query today's cumulative totals immediately.
    func refresh() {
        querySum(of: stepType, unit: .count()) { [weak self] value in
            self?.todaySteps = value.map { Int($0) }
        }
        querySum(of: distanceType, unit: .meter()) { [weak self] value in
            self?.todayMeters = value
        }
    }

    // MARK: - Internals

    private func beginObserving() {
        for type in [stepType, distanceType] {
            let q = HKObserverQuery(sampleType: type, predicate: nil) {
                [weak self] _, completion, _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
                completion()
            }
            store.execute(q)
            observerQueries.append(q)
        }
    }

    private func querySum(of type: HKQuantityType,
                          unit: HKUnit,
                          completion: @escaping @MainActor (Double?) -> Void) {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate
        )
        let q = HKStatisticsQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, stats, _ in
            let value = stats?.sumQuantity()?.doubleValue(for: unit)
            Task { @MainActor in completion(value) }
        }
        store.execute(q)
    }
}

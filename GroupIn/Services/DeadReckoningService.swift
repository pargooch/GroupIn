//
//  DeadReckoningService.swift
//  GroupIn
//
//  Pedestrian dead reckoning — keeps a useful position estimate when
//  GPS goes blind (indoors, underground, dense urban canyons). Anchors
//  on every fresh GPS fix and integrates pedometer steps × current
//  heading to estimate displacement from there.
//
//  Step length is calibrated *per user* by comparing GPS distance to
//  step count during outdoor walking windows. The personal step length
//  is persisted across sessions; on a fresh install we fall back to
//  the population-average 0.7m until enough calibration windows have
//  accumulated.
//
//  Accuracy heuristic: a dead-reckoned position's accuracy grows by
//  5% of the distance walked since the last GPS anchor. So 200m of
//  indoor walking after a 10m-accuracy fix produces a 20m bubble; the
//  UI's accuracy ring grows as the user wanders further from where
//  GPS last worked.
//

import Foundation
import CoreLocation
import CoreMotion

@MainActor
protocol DeadReckoningServicing: AnyObject {
    /// Stream of integrated dead-reckoned position estimates. Yields
    /// roughly on every pedometer update batch (every few seconds
    /// while the user is walking). AppState only consumes these when
    /// GPS is stale.
    var positionUpdates: AsyncStream<PositionEstimate> { get }

    /// Stream of step batches from CMPedometer — each batch carries the
    /// number of *new* steps since the last yield, plus the time window
    /// they happened in. Fires whether or not there's a GPS anchor
    /// (position estimates need an anchor, step deltas don't), so this
    /// is the signal the compass engine uses to integrate synthetic
    /// position spread for indoor finding. The compass consumer spreads
    /// the batch's steps across `[startDate, endDate]` so each step
    /// projects in the heading the device was actually pointing at
    /// *that* instant — not a single stale heading sampled when the
    /// batch landed.
    var stepUpdates: AsyncStream<StepBatch> { get }

    /// Start CMPedometer step counting unconditionally — independent
    /// of the GPS anchor that `reanchor(to:)` sets up. Used by
    /// `stepUpdates` so the compass can advance synthetic positions
    /// even when GPS never fires (indoors). Idempotent.
    func startStepObservation()

    /// Re-anchor to a fresh GPS fix. Resets the displacement
    /// integrator and feeds the calibration window if the prior
    /// anchor's GPS run produced enough signal.
    func reanchor(to fix: LocationFix)

    /// Keep the integrator aware of the latest heading so steps
    /// project in the right direction.
    func updateHeading(_ heading: Double)

    /// Stop pedometer updates and clear state. Called when the user
    /// leaves all groups (tracking lifecycle wind-down).
    func stop()

    /// Currently-calibrated personal step length in meters. Exposed
    /// for the diagnostics UI / future inspection.
    var calibratedStepLength: Double { get }
}

@MainActor
final class DeadReckoningService: DeadReckoningServicing {

    // MARK: - Streams

    let positionUpdates: AsyncStream<PositionEstimate>
    private nonisolated let positionContinuation: AsyncStream<PositionEstimate>.Continuation
    let stepUpdates: AsyncStream<StepBatch>
    private nonisolated let stepContinuation: AsyncStream<StepBatch>.Continuation

    /// `endDate` of the previous yielded batch. Used as the next
    /// batch's `startDate` so spread-over-window interpolation lines
    /// up step-to-step instead of restarting from `data.startDate`
    /// every callback (which would double-count the dead time
    /// between batches).
    private var lastYieldedEndDate: Date?

    /// Total CMPedometer step count observed since `startStepObservation`
    /// first kicked off. Used to compute the delta each batch yields.
    /// Distinct from the anchor-relative count `handlePedometerUpdate`
    /// uses for displacement — that one resets every reanchor; this one
    /// only resets on `stop()`.
    private var lastObservedStepCount: Int = 0
    private var stepObservationRunning: Bool = false

    // MARK: - State

    private let pedometer = CMPedometer()

    /// The GPS fix we're integrating displacement from. Set on every
    /// `reanchor(to:)`; nil before the first GPS fix arrives this
    /// session.
    private var anchor: AnchorPoint?

    /// Latest CMPedometerData since the current anchor. The delta
    /// from one update to the next gives us the slice of motion to
    /// apply on each tick.
    private var latestPedometerData: CMPedometerData?

    /// Most recent heading, in degrees clockwise from true north.
    /// Updated by AppState's heading consumer feeding into this
    /// service. Defaults to 0 (north) so the first DR projection
    /// doesn't go to nan if heading hasn't been seeded yet — though
    /// in practice CLHeading fires before pedometer in any realistic
    /// session.
    private var lastHeading: Double = 0

    /// Per-user calibration — `calibratedStepLength` evolves toward
    /// the user's actual stride via EWMA of GPS/pedometer-paired
    /// windows. Loaded from UserDefaults on init; persisted on every
    /// update so the next launch starts from where the user left off.
    private(set) var calibratedStepLength: Double

    /// Anchor data for the *previous* GPS window so we can compare
    /// against the new anchor when calibration fires. We collect:
    /// the coordinate + step count at window start, then on re-anchor
    /// compute the haversine distance and number of steps in between.
    private var calibrationWindowStart: CalibrationWindowStart?

    // MARK: - Constants

    /// Cold-start fallback when no calibration data exists yet.
    /// 0.7m is the population-average adult stride length on flat
    /// surfaces at moderate pace.
    static let defaultStepLength: Double = 0.7

    /// EWMA blending factor — α=0.1 means each new sample contributes
    /// 10% of the running average. Slow to update so one weird walk
    /// (e.g. dragging a suitcase) doesn't poison the personal stride.
    private static let calibrationAlpha: Double = 0.1

    /// Minimum requirements to count a window for calibration. Below
    /// these, signal is too weak to trust.
    private static let minStepsForCalibration: Int = 15
    private static let minDistanceForCalibration: Double = 10.0  // meters

    /// Maximum walking pace before we suspect non-pedestrian motion
    /// (driving, cycling, scooter). 6 mph = 2.68 m/s; anything above
    /// disqualifies the window from pedestrian calibration.
    private static let maxPaceForCalibration: Double = 2.68

    /// Pedestrian DR drift heuristic — error grows by 5% of distance
    /// walked since the GPS anchor. Industry-standard rule of thumb
    /// for foot-traffic INS.
    private static let driftFactor: Double = 0.05

    /// UserDefaults key for persisting the calibrated step length.
    private static let calibrationKey = "GroupIn.DeadReckoning.stepLength"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let (stream, cont) = AsyncStream.makeStream(of: PositionEstimate.self)
        self.positionUpdates = stream
        self.positionContinuation = cont
        let (stepStream, stepCont) = AsyncStream.makeStream(of: StepBatch.self)
        self.stepUpdates = stepStream
        self.stepContinuation = stepCont
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.calibrationKey)
        self.calibratedStepLength = stored > 0 ? stored : Self.defaultStepLength
    }

    // MARK: - Public surface

    func reanchor(to fix: LocationFix) {
        // Close the previous calibration window if there was one and
        // the elapsed walk produced enough signal.
        if let start = calibrationWindowStart, let prev = anchor {
            calibrate(windowStart: start, previousAnchor: prev, newFix: fix)
        }

        // Open a new anchor and calibration window. Pedometer resets
        // to count from the new anchor time.
        let next = AnchorPoint(
            coordinate: fix.coordinate,
            timestamp: fix.timestamp,
            accuracy: fix.accuracy
        )
        anchor = next
        calibrationWindowStart = CalibrationWindowStart(
            coordinate: fix.coordinate,
            timestamp: fix.timestamp
        )
        latestPedometerData = nil

        guard CMPedometer.isStepCountingAvailable() else { return }

        // CMPedometer.startUpdates can be called repeatedly without
        // explicit stop in between — each new start replaces the
        // previous query. This is what we want when re-anchoring
        // from one GPS fix to the next.
        pedometer.startUpdates(from: fix.timestamp) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                self?.handlePedometerUpdate(data)
            }
        }
    }

    func updateHeading(_ heading: Double) {
        lastHeading = heading
    }

    func startStepObservation() {
        guard !stepObservationRunning,
              CMPedometer.isStepCountingAvailable() else { return }
        stepObservationRunning = true
        // From "now" rather than a historical date so the first batch
        // doesn't dump backlog steps into the compass at once. We want
        // step deltas that correspond to the user's current motion
        // session, not the morning commute.
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                self?.handlePedometerUpdate(data)
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        anchor = nil
        latestPedometerData = nil
        calibrationWindowStart = nil
        stepObservationRunning = false
        lastObservedStepCount = 0
        lastYieldedEndDate = nil
    }

    // MARK: - Pedometer integration

    private func handlePedometerUpdate(_ data: CMPedometerData) {
        // Yield a step delta unconditionally. The compass uses this to
        // advance synthetic positions even when there's no GPS anchor
        // — which is the only viable path indoors. Position estimation
        // below still requires an anchor, as before.
        let totalSteps = data.numberOfSteps.intValue
        let delta = max(0, totalSteps - lastObservedStepCount)
        if delta > 0 {
            lastObservedStepCount = totalSteps
            // `data.startDate` is the absolute window start for the
            // whole query (often "now-ish" at startStepObservation
            // time), not the start of just *this* delta. Use the
            // previous yield's `endDate` as a tighter lower bound;
            // fall back to `data.startDate` on the first batch.
            let batchStart = lastYieldedEndDate ?? data.startDate
            let batch = StepBatch(
                delta: delta,
                startDate: batchStart,
                endDate: data.endDate
            )
            lastYieldedEndDate = data.endDate
            stepContinuation.yield(batch)
        }

        guard let anchor else { return }

        // Total distance from anchor. Prefer CMPedometerData.distance
        // when the device reports it (newer iPhones with motion
        // coprocessor expose it); fall back to step count × our
        // calibrated personal step length otherwise.
        let distance: Double
        if let measured = data.distance?.doubleValue, measured > 0 {
            distance = measured
        } else {
            distance = data.numberOfSteps.doubleValue * calibratedStepLength
        }

        // Project the displacement using the latest heading. Heading
        // is degrees clockwise from true north: north=0, east=90,
        // south=180, west=270. Convert to a north/east meter offset
        // then flat-earth-project to lat/lon.
        let headingRad = lastHeading * .pi / 180.0
        let east = distance * sin(headingRad)
        let north = distance * cos(headingRad)

        let earthRadius = 6_371_000.0
        let dLat = north / earthRadius * 180.0 / .pi
        let cosLat = cos(anchor.coordinate.latitude * .pi / 180.0)
        let dLon = east / (earthRadius * cosLat) * 180.0 / .pi

        let projected = Coordinate(
            latitude: anchor.coordinate.latitude + dLat,
            longitude: anchor.coordinate.longitude + dLon
        )

        // Accuracy bubble: anchor accuracy + 5% drift. Caps at a
        // generous 500m so the ring doesn't dominate the map for
        // marathon indoor walks.
        let drAccuracy = min(500.0, anchor.accuracy + distance * Self.driftFactor)

        let estimate = PositionEstimate(
            coordinate: projected,
            accuracy: drAccuracy,
            source: .deadReckoning,
            anchorAt: anchor.timestamp,
            sourcePeerID: nil,
            computedAt: data.endDate
        )

        latestPedometerData = data
        positionContinuation.yield(estimate)
    }

    // MARK: - Calibration

    /// When a GPS window closes (a new anchor replaces a prior one),
    /// compare the ground-truth GPS displacement to the pedometer
    /// step count over the same window. If both signals are strong
    /// and consistent with pedestrian motion, update the personal
    /// step length via EWMA. Filters out vehicles, cycling, and
    /// noise windows.
    private func calibrate(windowStart: CalibrationWindowStart,
                           previousAnchor: AnchorPoint,
                           newFix: LocationFix) {
        guard let pedometerData = latestPedometerData else { return }
        let steps = pedometerData.numberOfSteps.intValue
        guard steps >= Self.minStepsForCalibration else { return }

        let distance = haversineDistance(
            from: windowStart.coordinate,
            to: newFix.coordinate
        )
        guard distance >= Self.minDistanceForCalibration else { return }

        let elapsed = newFix.timestamp.timeIntervalSince(windowStart.timestamp)
        guard elapsed > 0 else { return }
        let pace = distance / elapsed
        guard pace <= Self.maxPaceForCalibration else { return }
        _ = previousAnchor  // explicitly unused — kept in signature for context

        // Single-window sample: distance ÷ steps. Blend into the
        // running EWMA. Persist after every update so the next
        // launch sees the latest value.
        let sample = distance / Double(steps)
        let blended = (Self.calibrationAlpha * sample)
            + ((1.0 - Self.calibrationAlpha) * calibratedStepLength)
        calibratedStepLength = blended
        defaults.set(blended, forKey: Self.calibrationKey)
    }

    /// Great-circle distance in meters between two coordinates.
    /// Pulled inline (rather than imported from CoreLocation's
    /// CLLocation.distance(from:)) so calibration doesn't allocate
    /// CLLocation objects on every window close.
    private func haversineDistance(from a: Coordinate, to b: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180.0
        let lat2 = b.latitude * .pi / 180.0
        let dLat = (b.latitude - a.latitude) * .pi / 180.0
        let dLon = (b.longitude - a.longitude) * .pi / 180.0
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadius * c
    }
}

// MARK: - Public types

/// One pedometer batch: `delta` new steps that landed in the window
/// `[startDate, endDate]`. The compass consumer interpolates each
/// step's individual timestamp across that window so the orientation
/// service can be queried at the moment each step was taken.
struct StepBatch: Sendable {
    let delta: Int
    let startDate: Date
    let endDate: Date
}

// MARK: - Internal types

private struct AnchorPoint {
    let coordinate: Coordinate
    let timestamp: Date
    let accuracy: Double
}

private struct CalibrationWindowStart {
    let coordinate: Coordinate
    let timestamp: Date
}

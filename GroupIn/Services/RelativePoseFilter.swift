//
//  RelativePoseFilter.swift
//  GroupIn
//
//  A standalone Extended Kalman Filter for cooperative phone-to-phone
//  relative localization. This is the channel *fuser* that replaces the
//  channel *selector*: instead of picking UWB OR BLE OR motion, it fuses
//  every available observation — UWB range+direction, BLE gradient
//  bearing, RSSI path-loss distance, and our own dead-reckoning /VIO
//  motion — into a single relative-position estimate with covariance.
//
//  State (2-D, seeker's local true-north world frame, metres):
//
//      x = [ px, py, vx, vy ]ᵀ
//
//  where py = north, px = east. The position is the sought peer's
//  location *relative to us*, so our own motion enters as a subtraction
//  in the prediction step (move north and a peer ahead of us gets
//  closer in py). 2-D is deliberate: a finder cares about azimuth +
//  distance, not elevation. SE(3) would be overkill and numerically
//  brittle for this job.
//
//  Reference EKF recursion implemented here:
//      predict:  x⁻ = F x                P⁻ = F P Fᵀ + Q
//      update:   K  = P⁻ Hᵀ (H P⁻ Hᵀ + R)⁻¹
//                x  = x⁻ + K (z − h(x⁻))
//                P  = (I − K H) P⁻        (Joseph form used for stability)
//
//  No dependencies beyond Foundation / simd. Pure value math. The whole
//  app is main-actor, so this is too; all state lives and mutates there.
//

import Foundation
import simd

@MainActor
final class RelativePoseFilter {

    // MARK: - Public estimate

    /// A single, view-ready snapshot of the filter's belief.
    struct Estimate {
        /// Bearing of the peer relative to us, degrees, 0 = north,
        /// increasing clockwise (compass convention: 90 = east).
        let bearingDegrees: Double
        /// Straight-line distance to the peer, metres.
        let distanceMetres: Double
        /// Single scalar confidence: sqrt(trace of the 2×2 position
        /// covariance / 2) — the RMS positional standard deviation in
        /// metres. Smaller is more confident.
        let positionStdDevMetres: Double
        /// True once `positionStdDevMetres` drops below
        /// `convergenceStdDevMetres`.
        let isConverged: Bool
    }

    // MARK: - Tuning constants
    //
    // Exposed as named constants so they can be reasoned about and
    // re-tuned in one place rather than buried in the math.

    /// Process noise on position, m²/s. How fast positional certainty
    /// decays between corrections from unmodelled effects (the peer is
    /// not perfectly constant-velocity). Kept modest so a still filter
    /// doesn't drift, but large enough to stay responsive.
    private let positionProcessNoise: Double = 0.3
    /// Process noise on velocity, (m/s)²/s. The peer can accelerate;
    /// this is the dominant driver of covariance growth when no
    /// observations arrive.
    private let velocityProcessNoise: Double = 0.5

    /// Bearing-update noise mapping: a confidence of 0 maps to this many
    /// radians of sigma (60°), confidence 1 to `bearingSigmaFloorRad`.
    private let bearingSigmaSpanRad: Double = 60.0 * .pi / 180.0
    /// Floor for bearing sigma even at full confidence (2°). A perfect
    /// confidence should not imply zero noise — that would make the
    /// gradient bearing infinitely trusted.
    private let bearingSigmaFloorRad: Double = 2.0 * .pi / 180.0

    /// Mahalanobis innovation-gating threshold. A scalar update whose
    /// normalized innovation squared (νᵀ S⁻¹ ν) exceeds this is rejected
    /// outright. 9.0 ≈ 3σ for a 1-DoF measurement; keeps a wild RSSI or
    /// reflected bearing sample from yanking the estimate. For the 2-DoF
    /// UWB joint update we use `gateThreshold2DoF`.
    private let gateThreshold: Double = 9.0
    /// Gating threshold for the 2-DoF UWB joint (range+bearing) update.
    /// 13.8 ≈ 99.9th percentile of χ²(2); a touch looser than two
    /// independent 1-DoF gates because UWB is our most trusted source.
    private let gateThreshold2DoF: Double = 13.8

    /// Convergence cutoff: position RMS std-dev below this (metres) and
    /// `isConverged` flips true.
    private let convergenceStdDevMetres: Double = 3.0

    /// Initial position variance seeded on first observation, m². Big —
    /// we want the first few corrections to dominate the prior.
    private let initialPositionVariance: Double = 25.0
    /// Initial velocity variance seeded on first observation, (m/s)².
    /// The peer's velocity is completely unknown at init.
    private let initialVelocityVariance: Double = 4.0

    /// Lower bound on radial distance used in Jacobian denominators, to
    /// avoid divide-by-zero / blow-up when the estimate sits on the
    /// origin (peer is exactly on top of us — degenerate for bearing).
    private let minRadius: Double = 0.05

    // MARK: - Filter state

    /// State vector [px, py, vx, vy]ᵀ. `nil` until first init.
    private var x: SIMD4<Double>?
    /// State covariance, 4×4. Valid iff `x != nil`.
    private var P: simd_double4x4 = simd_double4x4(0)

    // MARK: - Lifecycle

    /// Reset to uninitialized — peer lost, or a new seeking session.
    func reset() {
        x = nil
        P = simd_double4x4(0)
    }

    /// Whether the filter holds a valid estimate yet.
    var isInitialized: Bool { x != nil }

    // MARK: - Estimate readout

    /// Current best estimate, or nil before initialization.
    var estimate: Estimate? {
        guard let x else { return nil }
        let px = x.x
        let py = x.y
        let distance = sqrt(px * px + py * py)

        // Bearing in compass convention: 0 = north, clockwise. Note
        // atan2(east, north) — args swapped vs. the textbook
        // atan2(y, x) — to rotate the zero to north and run clockwise.
        var bearing = atan2(px, py) * 180.0 / .pi
        if bearing < 0 { bearing += 360 }

        // Position covariance is the top-left 2×2 block of P. Its trace
        // is varₚₓ + varₚy; halving and rooting gives an RMS per-axis
        // std-dev — one number that shrinks as either axis tightens.
        let posTrace = P[0][0] + P[1][1]
        let stdDev = sqrt(max(posTrace, 0) / 2.0)

        return Estimate(
            bearingDegrees: bearing,
            distanceMetres: distance,
            positionStdDevMetres: stdDev,
            isConverged: stdDev < convergenceStdDevMetres
        )
    }

    // MARK: - Prediction

    /// Prediction step. Call on each of OUR motion increments, sourced
    /// from VIO odometry or pedestrian dead reckoning.
    ///
    /// - Parameters:
    ///   - dx: our eastward displacement (m) in the world frame since
    ///         the last predict.
    ///   - dy: our northward displacement (m) in the world frame since
    ///         the last predict.
    ///   - dt: elapsed time (s); drives process-noise growth.
    ///
    /// Constant-velocity model. The transition is
    ///
    ///     F = | 1 0 dt 0 |
    ///         | 0 1 0 dt |
    ///         | 0 0 1  0 |
    ///         | 0 0 0  1 |
    ///
    /// so x⁻ = F x propagates position by velocity·dt. Because the state
    /// is the peer's position *relative to us*, our own displacement
    /// (dx, dy) is then *subtracted* from (px, py): if we step north,
    /// a peer who is ahead of us becomes northwardly closer, so py
    /// decreases by our dy. (This is a deterministic control input,
    /// not a measurement — it shifts the mean but adds no information.)
    func predict(ourDeltaEast dx: Double, ourDeltaNorth dy: Double, dt: TimeInterval) {
        guard var state = x else { return }
        let dt = max(dt, 0)

        // x⁻ = F x : advance position by velocity, then subtract our
        // own world-frame motion from the relative position.
        let px = state.x + state.z * dt - dx
        let py = state.y + state.w * dt - dy
        let vx = state.z
        let vy = state.w
        state = SIMD4<Double>(px, py, vx, vy)
        x = state

        // P⁻ = F P Fᵀ + Q.
        let F = transitionMatrix(dt: dt)
        var newP = F * P * F.transpose
        newP += processNoise(dt: dt)
        P = symmetrized(newP)
    }

    /// Constant-velocity transition matrix for the given dt.
    private func transitionMatrix(dt: Double) -> simd_double4x4 {
        // simd_double4x4(columns:) is column-major: each SIMD4 is a
        // COLUMN. Column j holds the coefficients multiplying state j
        // across all output rows. The dt terms therefore live in the
        // velocity columns (2 and 3), row px / py respectively.
        let c0 = SIMD4<Double>(1, 0, 0, 0)   // column for px
        let c1 = SIMD4<Double>(0, 1, 0, 0)   // column for py
        let c2 = SIMD4<Double>(dt, 0, 1, 0)  // column for vx → row px gets dt
        let c3 = SIMD4<Double>(0, dt, 0, 1)  // column for vy → row py gets dt
        return simd_double4x4(columns: (c0, c1, c2, c3))
    }

    /// Discrete process-noise covariance Q, scaled by dt. We use a
    /// simple diagonal: position and velocity each accrue independent
    /// random-walk noise. This is the pragmatic ("piecewise white
    /// noise") form rather than the full continuous-time integral —
    /// adequate here and easy to tune via the two named constants.
    private func processNoise(dt: Double) -> simd_double4x4 {
        let qp = positionProcessNoise * dt
        let qv = velocityProcessNoise * dt
        let c0 = SIMD4<Double>(qp, 0, 0, 0)
        let c1 = SIMD4<Double>(0, qp, 0, 0)
        let c2 = SIMD4<Double>(0, 0, qv, 0)
        let c3 = SIMD4<Double>(0, 0, 0, qv)
        return simd_double4x4(columns: (c0, c1, c2, c3))
    }

    // MARK: - Corrections (public)

    /// Strong correction from UWB: a distance plus a device-frame
    /// direction unit vector. We rotate the direction into the world
    /// frame using the supplied heading (degrees clockwise from north),
    /// derive a world-frame bearing, and apply range + bearing together.
    ///
    /// - Parameters:
    ///   - distance: measured range, metres.
    ///   - directionEast / directionNorth: components of the *world-frame*
    ///     direction unit vector toward the peer. (The integrating code
    ///     is expected to have already mapped the NISession device-frame
    ///     vector through heading; we normalize defensively here and use
    ///     it directly — the API takes world-frame components.)
    ///   - sigma: 1σ uncertainty, metres for range / radians-equivalent
    ///     for bearing. UWB is precise, so this should be small (~0.3).
    func updateUWB(distance: Double, directionEast: Double, directionNorth: Double, sigma: Double) {
        // Derive a world-frame bearing from the direction vector.
        // atan2(east, north) → clockwise-from-north, matching the state.
        let mag = sqrt(directionEast * directionEast + directionNorth * directionNorth)

        // Seed if uninitialized: position = distance × direction.
        if x == nil {
            if mag > 1e-6 {
                let px = distance * directionEast / mag
                let py = distance * directionNorth / mag
                seed(px: px, py: py)
            } else {
                // No usable direction — fall back to a range-only seed
                // (places the peer due north at `distance`; the bearing
                // is unknown but range pins the radius and subsequent
                // corrections rotate it in).
                seed(px: 0, py: distance)
            }
            return
        }

        // Range part: small sigma in metres.
        applyRangeUpdate(distance: distance, sigma: sigma, gate: gateThreshold2DoF)

        // Bearing part: convert UWB direction to a bearing and apply.
        // Use a bearing sigma scaled from the metric sigma at the
        // current range — a fixed cross-range error of `sigma` metres
        // subtends sigma/r radians. Clamp to a sane minimum so a far
        // peer doesn't get an unrealistically tight angle.
        if mag > 1e-6 {
            let bearingRad = atan2(directionEast / mag, directionNorth / mag)
            let r = max(currentRadius(), minRadius)
            let bearingSigma = max(sigma / r, bearingSigmaFloorRad)
            applyBearingUpdate(bearingRad: bearingRad, sigmaRad: bearingSigma, gate: gateThreshold2DoF)
        }
    }

    /// UWB (or any source's) distance-only correction, used when no
    /// direction vector is available.
    func updateRange(distance: Double, sigma: Double) {
        if x == nil {
            // Range-only seed: peer placed due north at `distance`.
            // Bearing is unconstrained until a bearing observation
            // arrives, but the radius is correct from the first frame.
            seed(px: 0, py: distance)
            return
        }
        applyRangeUpdate(distance: distance, sigma: sigma, gate: gateThreshold)
    }

    /// Weak correction from the BLE RSSI-gradient compass: a world-frame
    /// bearing (degrees clockwise from north) with a confidence in
    /// [0, 1]. Confidence maps to measurement noise — low confidence →
    /// wide sigma → little pull.
    func updateBearing(degrees: Double, confidence: Double) {
        let c = min(max(confidence, 0), 1)
        // sigma_rad = (1 − confidence)·60° + 2°. Full confidence still
        // leaves a 2° floor; zero confidence opens to 62°.
        let sigmaRad = (1 - c) * bearingSigmaSpanRad + bearingSigmaFloorRad
        let bearingRad = degrees * .pi / 180.0

        if x == nil {
            // Can't seed position from a bearing alone (no radius). Wait
            // for a range/UWB observation to initialize. Drop silently.
            return
        }
        applyBearingUpdate(bearingRad: bearingRad, sigmaRad: sigmaRad, gate: gateThreshold)
    }

    /// Weak correction: a coarse distance from RSSI path-loss, with a
    /// (large) sigma reflecting how unreliable RSSI ranging is.
    func updateRangeRSSI(distance: Double, sigma: Double) {
        if x == nil {
            seed(px: 0, py: distance)
            return
        }
        applyRangeUpdate(distance: distance, sigma: sigma, gate: gateThreshold)
    }

    // MARK: - Initialization helper

    /// Seed the filter from a first position fix with generous
    /// covariance and zero initial velocity.
    private func seed(px: Double, py: Double) {
        x = SIMD4<Double>(px, py, 0, 0)
        let c0 = SIMD4<Double>(initialPositionVariance, 0, 0, 0)
        let c1 = SIMD4<Double>(0, initialPositionVariance, 0, 0)
        let c2 = SIMD4<Double>(0, 0, initialVelocityVariance, 0)
        let c3 = SIMD4<Double>(0, 0, 0, initialVelocityVariance)
        P = simd_double4x4(columns: (c0, c1, c2, c3))
    }

    // MARK: - Scalar EKF update primitives

    private func currentRadius() -> Double {
        guard let x else { return 0 }
        return sqrt(x.x * x.x + x.y * x.y)
    }

    /// Range measurement update.
    ///
    /// Measurement model: h(x) = sqrt(px² + py²) = r.
    /// Jacobian (∂h/∂x): differentiate r w.r.t. each state →
    ///     ∂r/∂px = px/r, ∂r/∂py = py/r, ∂r/∂vx = ∂r/∂vy = 0.
    /// so H = [ px/r, py/r, 0, 0 ].
    private func applyRangeUpdate(distance: Double, sigma: Double, gate: Double) {
        guard let state = x else { return }
        let px = state.x, py = state.y
        let r = max(sqrt(px * px + py * py), minRadius)

        let H = SIMD4<Double>(px / r, py / r, 0, 0)
        let innovation = distance - r          // z − h(x⁻); linear domain, no wrap
        let R = sigma * sigma
        applyScalarUpdate(H: H, innovation: innovation, R: R, gate: gate)
    }

    /// Bearing measurement update.
    ///
    /// Measurement model: h(x) = atan2(px, py) — clockwise-from-north,
    /// matching the compass convention used everywhere in the app.
    /// Jacobian (∂h/∂x): with θ = atan2(px, py) and r² = px² + py²,
    ///     ∂θ/∂px =  py / r²,
    ///     ∂θ/∂py = −px / r²,
    /// (velocity terms zero). so H = [ py/r², −px/r², 0, 0 ].
    /// The innovation (z − h) is wrapped into [−π, π] so a measurement
    /// at +179° vs. a prediction at −179° produces a small +2° error,
    /// not a −358° one.
    private func applyBearingUpdate(bearingRad: Double, sigmaRad: Double, gate: Double) {
        guard let state = x else { return }
        let px = state.x, py = state.y
        let r2 = max(px * px + py * py, minRadius * minRadius)

        let H = SIMD4<Double>(py / r2, -px / r2, 0, 0)
        let predicted = atan2(px, py)
        let innovation = wrapToPi(bearingRad - predicted)
        let R = sigmaRad * sigmaRad
        applyScalarUpdate(H: H, innovation: innovation, R: R, gate: gate)
    }

    /// Shared scalar-measurement EKF correction with innovation gating
    /// and Joseph-form covariance update.
    ///
    /// For a scalar measurement, S = H P⁻ Hᵀ + R is a scalar, so the
    /// matrix inverse collapses to a reciprocal and the Kalman gain is
    /// K = P⁻ Hᵀ / S (a 4-vector).
    private func applyScalarUpdate(H: SIMD4<Double>, innovation: Double, R: Double, gate: Double) {
        guard let state = x else { return }

        // P Hᵀ — matrix·vector. simd's matrix*vector treats the vector
        // as a column, exactly what we want for the 4×1 result.
        let PHt = P * H
        // S = H P Hᵀ + R  (scalar).
        let S = dot(H, PHt) + R
        guard S > 0 else { return }

        // Innovation gating: reject if Mahalanobis distance ν²/S
        // exceeds the χ²-style threshold. Stops a single wild sample
        // (reflected RSSI, multipath bearing) from dragging the state.
        let mahalanobis = (innovation * innovation) / S
        if mahalanobis > gate { return }

        // Kalman gain K = P Hᵀ / S.
        let K = PHt / S

        // State update x = x⁻ + K·ν.
        x = state + K * innovation

        // Joseph-form covariance update:
        //   P = (I − K H) P (I − K H)ᵀ + K R Kᵀ
        // More numerically robust than (I − KH)P — stays symmetric and
        // positive-(semi)definite even with marginal arithmetic.
        let KH = outerProduct(K, H)          // 4×4
        let I = matrixIdentity4()
        let IKH = I - KH
        let KRKt = outerProduct(K, K) * R    // K R Kᵀ, R scalar
        let newP = IKH * P * IKH.transpose + KRKt
        P = symmetrized(newP)
    }

    // MARK: - Linear-algebra helpers (simd)

    /// Outer product a·bᵀ as a 4×4 matrix. Column j is a · b[j].
    private func outerProduct(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> simd_double4x4 {
        simd_double4x4(columns: (a * b.x, a * b.y, a * b.z, a * b.w))
    }

    private func matrixIdentity4() -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4<Double>(1, 1, 1, 1))
    }

    /// Force symmetry: P = (P + Pᵀ)/2. Cleans up the small asymmetries
    /// that accumulate from floating-point round-off and keeps the
    /// covariance well-formed for the next step.
    private func symmetrized(_ m: simd_double4x4) -> simd_double4x4 {
        (m + m.transpose) * 0.5
    }

    /// Wrap an angle (radians) into [−π, π]. Used for the bearing
    /// innovation so wrap-around never produces a spurious giant error.
    private func wrapToPi(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}

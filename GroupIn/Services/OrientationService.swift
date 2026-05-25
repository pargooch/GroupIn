//
//  OrientationService.swift
//  GroupIn
//
//  Precision motion sensing — high-rate device-motion sampling for
//  per-step heading recovery, plus a fallback "where is the user actually
//  walking?" inference from the principal axis of recent horizontal-frame
//  acceleration.
//
//  Two signals consumed by the compass step pipeline:
//
//    1. `headingDegrees(at:)` — buffered attitude lookup. Each pedometer
//       step has a real timestamp; the compass projects that step in the
//       heading the device was actually pointing at *that* instant, not
//       whatever heading was current when the pedometer batch fired (which
//       can lag by 2-3 s on cold pockets).
//
//    2. `motionHeading()` — recovers walking direction from a 2 s window
//       of world-frame user acceleration. Walking produces a strong
//       directional axis in the horizontal plane; PCA on (east, north)
//       acceleration samples gives that axis. Used when CMAttitude heading
//       is unreliable (low magnetic-field quality) or when the user has
//       the phone in a pocket / bag (device heading ≠ walking heading).
//
//  Lifecycle: started/stopped by AppState alongside the rest of the
//  BLE-presence-tier services. CMMotionActivity gates motionHeading to
//  walking-confirmed windows so we don't infer a direction from the
//  Brownian noise of a phone sitting on a desk.
//

import Foundation
import CoreMotion
import simd

@MainActor
final class OrientationService {

    // MARK: - Sample

    struct AttitudeSample: Sendable {
        let timestamp: Date
        let headingDegrees: Double
        let gravity: SIMD3<Double>
        let userAcceleration: SIMD3<Double>
        let rotationRate: SIMD3<Double>   // gyro, rad/s
        let isReliable: Bool
    }

    /// Live read-out for the debug telemetry panel. All current
    /// instantaneous values plus the derived motion-heading.
    struct DebugSnapshot: Sendable, Equatable {
        var attitudeHeading: Double?
        var headingReliable: Bool
        var rotationRate: SIMD3<Double>
        var userAcceleration: SIMD3<Double>
        var gravity: SIMD3<Double>
        var motionHeading: Double?
        var motionConfidence: Double?
        var activity: String        // "walking" / "stationary" / "—"
        var activityConfidence: String
        var bufferCount: Int
    }

    // MARK: - Config

    /// 50 Hz device-motion. The reference relative-localization stack
    /// calls for 100–1000 Hz raw IMU; we don't integrate raw IMU for
    /// position (CMPedometer + VIO handle displacement, CMDeviceMotion
    /// gives us a pre-fused quaternion AHRS), so we don't need
    /// kilohertz. 50 Hz resolves a single step (~0.4–0.6 s) to ~25
    /// attitude samples — ample for per-step heading recovery — while
    /// the time-pruned ring buffer stays bounded at ~1000 entries for
    /// 20 s of history. Doubling 25→50 Hz is the cheapest fidelity
    /// win; going higher mostly burns battery for this use case.
    private static let updateInterval: TimeInterval = 0.02

    /// 20 s of history. Step batches typically lag <3 s; 20 s gives us
    /// generous margin for pocketed/idled deliveries.
    private static let bufferDuration: TimeInterval = 20.0

    /// `headingDegrees(at:)` rejects matches further than this from the
    /// requested timestamp.
    private static let matchTolerance: TimeInterval = 0.2

    /// PCA window — 2 s of samples for principal-axis extraction.
    private static let motionWindow: TimeInterval = 2.0

    /// Minimum samples in the PCA window before we trust the result.
    private static let motionMinSamples: Int = 30

    /// Eigenvalue floor for the principal axis. Below this the user
    /// likely isn't walking (or is walking so slowly that the noise
    /// floor dominates the signal).
    private static let motionLambdaThreshold: Double = 0.5

    // MARK: - State

    private let motionManager = CMMotionManager()
    private let activityManager = CMMotionActivityManager()

    private var buffer: [AttitudeSample] = []
    private var lastActivity: CMMotionActivity?
    private var lastMotionHeading: Double?
    private var isRunning: Bool = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = Self.updateInterval
            motionManager.startDeviceMotionUpdates(
                using: .xTrueNorthZVertical,
                to: OperationQueue.main
            ) { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.ingest(motion)
            }
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: OperationQueue.main) { [weak self] activity in
                guard let self else { return }
                self.lastActivity = activity
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
        activityManager.stopActivityUpdates()
        buffer.removeAll(keepingCapacity: false)
        lastActivity = nil
    }

    // MARK: - Ingestion

    private func ingest(_ motion: CMDeviceMotion) {
        let timestamp = Date(
            timeIntervalSinceNow: motion.timestamp - ProcessInfo.processInfo.systemUptime
        )

        // CMAttitude.heading is degrees clockwise from true north when
        // the reference frame is `xTrueNorthZVertical`. Negative values
        // (or values >= 360) get wrapped to [0, 360).
        let rawHeading = motion.heading
        let heading: Double
        if rawHeading.isFinite {
            let wrapped = rawHeading.truncatingRemainder(dividingBy: 360)
            heading = wrapped < 0 ? wrapped + 360 : wrapped
        } else {
            heading = 0
        }

        // Magnetic field quality is the only public signal we have for
        // whether the heading is trustworthy. `.high` ≈ recently
        // calibrated; below that, expect 10–40° error. Some devices /
        // older OS versions don't populate it at all — treat that as
        // reliable rather than throwing away every sample.
        let isReliable: Bool
        let field = motion.magneticField
        if field.accuracy == .uncalibrated {
            // Truly missing — could be feature unsupported or app
            // launched too soon. Don't penalise.
            isReliable = true
        } else {
            isReliable = field.accuracy.rawValue >= CMMagneticFieldCalibrationAccuracy.high.rawValue
        }

        let gravity = SIMD3<Double>(
            motion.gravity.x,
            motion.gravity.y,
            motion.gravity.z
        )
        let userAcc = SIMD3<Double>(
            motion.userAcceleration.x,
            motion.userAcceleration.y,
            motion.userAcceleration.z
        )
        let rotation = SIMD3<Double>(
            motion.rotationRate.x,
            motion.rotationRate.y,
            motion.rotationRate.z
        )

        let sample = AttitudeSample(
            timestamp: timestamp,
            headingDegrees: heading,
            gravity: gravity,
            userAcceleration: userAcc,
            rotationRate: rotation,
            isReliable: isReliable
        )
        buffer.append(sample)

        // Prune from the front. Linear scan is fine — buffer is at
        // most ~500 entries and samples arrive monotonically.
        let cutoff = timestamp.addingTimeInterval(-Self.bufferDuration)
        if let firstFresh = buffer.firstIndex(where: { $0.timestamp >= cutoff }), firstFresh > 0 {
            buffer.removeFirst(firstFresh)
        }
    }

    // MARK: - Queries

    /// Look up the heading at a specific moment. Returns nil if:
    ///   • the buffer is empty,
    ///   • the closest sample is more than `matchTolerance` away,
    ///   • or the matched sample was flagged unreliable.
    func headingDegrees(at time: Date) -> Double? {
        guard !buffer.isEmpty else { return nil }

        // Binary search for the first timestamp >= target.
        var lo = 0
        var hi = buffer.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if buffer[mid].timestamp < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Candidates: the entry at `lo` (first >= target) and `lo - 1`
        // (last < target). Pick whichever is closer in time.
        let upper = lo < buffer.count ? buffer[lo] : nil
        let lower = lo > 0 ? buffer[lo - 1] : nil

        let candidate: AttitudeSample?
        switch (lower, upper) {
        case let (l?, u?):
            let dl = abs(l.timestamp.timeIntervalSince(time))
            let du = abs(u.timestamp.timeIntervalSince(time))
            candidate = dl <= du ? l : u
        case let (l?, nil):
            candidate = l
        case let (nil, u?):
            candidate = u
        default:
            candidate = nil
        }

        guard let match = candidate else { return nil }
        let delta = abs(match.timestamp.timeIntervalSince(time))
        guard delta <= Self.matchTolerance else { return nil }
        guard match.isReliable else { return nil }
        return match.headingDegrees
    }

    /// Infer walking direction from the principal axis of horizontal-
    /// frame user acceleration over the last `motionWindow` seconds.
    ///
    /// Returns `(degrees, confidence)` or nil when the gates fail
    /// (not walking, not enough samples, or signal too weak).
    func motionHeading(now: Date = Date()) -> (degrees: Double, confidence: Double)? {
        // Activity gate — only trust this when CMMotionActivity says
        // the user is actually walking, and not at low confidence.
        if let activity = lastActivity {
            guard activity.walking else { return nil }
            guard activity.confidence != .low else { return nil }
        } else {
            // No activity info at all — refuse rather than guess.
            return nil
        }

        let cutoff = now.addingTimeInterval(-Self.motionWindow)
        let window = buffer.filter { $0.timestamp >= cutoff }
        guard window.count >= Self.motionMinSamples else { return nil }

        // Rotate each sample's userAcceleration (device frame, gravity-
        // free) into the world horizontal frame using its own heading.
        // We treat the device's x/y axes as the dominant horizontal
        // components — Core Motion already aligned them with the
        // reference frame in the device-motion callback.
        //
        // Convention: east = +x_world, north = +y_world. Heading is
        // clockwise from true north, so heading→radians→rotation:
        //   east  =  ax·cos(h) + ay·sin(h)
        //   north = -ax·sin(h) + ay·cos(h)
        var easts: [Double] = []
        var norths: [Double] = []
        easts.reserveCapacity(window.count)
        norths.reserveCapacity(window.count)
        for s in window {
            let h = s.headingDegrees * .pi / 180.0
            let ax = s.userAcceleration.x
            let ay = s.userAcceleration.y
            let e = ax * cos(h) + ay * sin(h)
            let n = -ax * sin(h) + ay * cos(h)
            easts.append(e)
            norths.append(n)
        }

        let n = Double(window.count)
        let meanE = easts.reduce(0, +) / n
        let meanN = norths.reduce(0, +) / n

        // Centered covariance — 2×2 symmetric.
        var cee = 0.0
        var cnn = 0.0
        var cen = 0.0
        for i in 0..<easts.count {
            let de = easts[i] - meanE
            let dn = norths[i] - meanN
            cee += de * de
            cnn += dn * dn
            cen += de * dn
        }
        cee /= n
        cnn /= n
        cen /= n

        // Closed-form 2×2 eigen-decomposition.
        // λ = (trace/2) ± sqrt((trace/2)² - det)
        let trace = cee + cnn
        let det = cee * cnn - cen * cen
        let halfTrace = trace / 2
        let radicand = max(0, halfTrace * halfTrace - det)
        let root = radicand.squareRoot()
        let lambda1 = halfTrace + root  // principal eigenvalue
        let lambda2 = max(halfTrace - root, .ulpOfOne)  // floor to avoid /0

        guard lambda1 > Self.motionLambdaThreshold else { return nil }

        // Principal eigenvector: (cen, lambda1 - cee), or (lambda1 - cnn, cen)
        // — pick whichever has greater magnitude for numerical stability.
        let vx1 = cen
        let vy1 = lambda1 - cee
        let vx2 = lambda1 - cnn
        let vy2 = cen
        let m1 = vx1 * vx1 + vy1 * vy1
        let m2 = vx2 * vx2 + vy2 * vy2
        let evx: Double
        let evy: Double
        if m1 >= m2 && m1 > 0 {
            evx = vx1
            evy = vy1
        } else if m2 > 0 {
            evx = vx2
            evy = vy2
        } else {
            return nil
        }

        // Axis in world frame: evx along east, evy along north.
        // Convert to a compass bearing (clockwise from north, 0..360).
        let bearingRad = atan2(evx, evy)
        var bearingDeg = bearingRad * 180.0 / .pi
        if bearingDeg < 0 { bearingDeg += 360 }

        // Sign ambiguity — the principal axis defines a line, not a
        // direction. Resolve via temporal continuity with the last
        // call's chosen direction. On cold start use the mean-vector
        // forward projection (positive ⇒ keep axis; negative ⇒ flip).
        let candidateA = bearingDeg
        let candidateB = (bearingDeg + 180).truncatingRemainder(dividingBy: 360)

        let chosen: Double
        if let last = lastMotionHeading {
            let dA = Self.angularDistance(candidateA, last)
            let dB = Self.angularDistance(candidateB, last)
            chosen = dA <= dB ? candidateA : candidateB
        } else {
            // Project the mean onto the axis. Positive = candidateA is
            // forward; negative = candidateB.
            let axMag = sqrt(evx * evx + evy * evy)
            let axx = axMag > 0 ? evx / axMag : 0
            let axy = axMag > 0 ? evy / axMag : 0
            let projection = meanE * axx + meanN * axy
            chosen = projection >= 0 ? candidateA : candidateB
        }

        // Confidence: how concentrated the variance is along the
        // principal axis. tanh keeps it bounded to [0, 1) for the
        // positive ratios we get when λ1 > λ2.
        let separation = (lambda1 - lambda2) / lambda2
        let confidence = max(0, min(1, tanh(separation)))

        lastMotionHeading = chosen
        return (chosen, confidence)
    }

    /// Shortest angular distance between two bearings in degrees,
    /// in [0, 180].
    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    // MARK: - Debug

    /// Snapshot every current motion value for the debug telemetry
    /// panel. Cheap — reads the last buffer entry + one motionHeading
    /// computation. Returns zeros when no samples have arrived yet.
    func debugSnapshot() -> DebugSnapshot {
        let latest = buffer.last
        let mh = motionHeading()
        let activityText: String
        let activityConf: String
        if let a = lastActivity {
            if a.walking { activityText = "walking" }
            else if a.running { activityText = "running" }
            else if a.stationary { activityText = "stationary" }
            else if a.automotive { activityText = "driving" }
            else { activityText = "unknown" }
            switch a.confidence {
            case .low: activityConf = "low"
            case .medium: activityConf = "med"
            case .high: activityConf = "high"
            @unknown default: activityConf = "?"
            }
        } else {
            activityText = "—"
            activityConf = "—"
        }
        return DebugSnapshot(
            attitudeHeading: latest?.headingDegrees,
            headingReliable: latest?.isReliable ?? false,
            rotationRate: latest?.rotationRate ?? .zero,
            userAcceleration: latest?.userAcceleration ?? .zero,
            gravity: latest?.gravity ?? .zero,
            motionHeading: mh?.degrees,
            motionConfidence: mh?.confidence,
            activity: activityText,
            activityConfidence: activityConf,
            bufferCount: buffer.count
        )
    }
}

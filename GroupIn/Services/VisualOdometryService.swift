//
//  VisualOdometryService.swift
//  GroupIn
//
//  ARKit visual-inertial odometry (VIO) — the seeker's own drift-free,
//  centimetre-scale local trajectory. It does NOT locate the peer; it
//  measures how *we* move. The relative-pose EKF fuses this ego-motion
//  with UWB range to triangulate the peer's bearing (range-only
//  localization needs accurate observer motion, and pedometer
//  dead-reckoning was too noisy for that).
//
//  Lifecycle: started ONLY while the compass is open (see
//  `AppState.startRelativePoseFusion`) and stopped on close — ARKit world
//  tracking keeps the rear camera streaming, so we never leave it running
//  in the background.
//
//  Frame: `.gravityAndHeading` aligns ARKit's world to gravity + true
//  north at session start, so the output is already east/north-aligned:
//      east  = +x,  north = -z   (y is up, dropped).
//

import Foundation
import ARKit
import simd

@MainActor
@Observable
final class VisualOdometryService: NSObject, ARSessionDelegate {

    /// True once ARKit reports `.normal` tracking.
    private(set) var isTracking = false
    /// Latest world-frame camera position (metres), or nil before the
    /// first tracked frame. Debug readout only.
    private(set) var position: SIMD3<Double>?
    /// Human-readable status for the debug panel.
    private(set) var statusText = "off"

    private let session = ARSession()
    private var isRunning = false

    /// The underlying ARSession, shared with `UWBSessionService` via
    /// `NISession.setARSession` so the SAME camera powers both VIO
    /// ego-motion AND camera-assisted UWB (no second ARSession, no camera
    /// conflict).
    var arSession: ARSession { session }

    /// Wall-clock-timestamped position history, so
    /// `horizontalDisplacement(since:)` can be queried with a `Date`.
    /// ARKit's `frame.timestamp` is a separate monotonic clock, so we
    /// stamp samples with `Date` on receipt instead.
    private struct Sample { let at: Date; let pos: SIMD3<Double> }
    private var buffer: [Sample] = []
    private var lastSampleAt: Date?
    private static let sampleInterval: TimeInterval = 0.1   // ~10 Hz into buffer
    private static let bufferWindow: TimeInterval = 30

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            statusText = "unsupported"
            return
        }
        // Running an ARSession opens the rear camera; iOS HARD-CRASHES any
        // app that touches the camera without `NSCameraUsageDescription`.
        // Guard so a missing key degrades to "disabled" instead of a
        // crash. Self-enables the moment the key is present.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            statusText = "disabled (add NSCameraUsageDescription)"
            return
        }
        isRunning = true
        // North-aligned so the EKF's bearing (built from VIO ego-motion)
        // is true-north-referenced and the arrow points correctly. VIO
        // is NOT shared with NISession anymore (camera assistance was
        // removed — it kept invalidating UWB), so the `.gravity`
        // restriction no longer applies.
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.planeDetection = []
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        statusText = "starting"
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
        buffer.removeAll(keepingCapacity: false)
        lastSampleAt = nil
        isTracking = false
        position = nil
        statusText = "off"
    }

    /// Horizontal-plane displacement since `date`, in the world east/north
    /// frame, metres — or nil if tracking isn't up or the buffer doesn't
    /// span `date`. Returns the motion between the buffered sample at/just
    /// after `date` and the most recent sample.
    func horizontalDisplacement(since date: Date) -> (east: Double, north: Double)? {
        guard isTracking, let current = buffer.last else { return nil }
        let past = buffer.first(where: { $0.at >= date }) ?? buffer.first
        guard let past else { return nil }
        let d = current.pos - past.pos
        return (east: Double(d.x), north: Double(-d.z))
    }

    // MARK: - ARSessionDelegate

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Extract value types before hopping actors — ARFrame is a class
        // and not Sendable.
        let col = frame.camera.transform.columns.3
        let pos = SIMD3<Double>(Double(col.x), Double(col.y), Double(col.z))
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        Task { @MainActor [weak self] in
            self?.applyFrame(pos: pos, normal: normal)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let reason = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.statusText = "error: \(reason)"
            self?.isTracking = false
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.isTracking = false
            self?.statusText = "interrupted"
        }
    }

    private func applyFrame(pos: SIMD3<Double>, normal: Bool) {
        guard isRunning else { return }
        position = pos
        isTracking = normal
        statusText = normal ? "tracking" : "limited"
        guard normal else { return }
        let now = Date()
        // Subsample to ~10 Hz.
        if let last = lastSampleAt, now.timeIntervalSince(last) < Self.sampleInterval {
            return
        }
        lastSampleAt = now
        buffer.append(Sample(at: now, pos: pos))
        // Trim to the rolling window.
        let cutoff = now.addingTimeInterval(-Self.bufferWindow)
        if let firstFresh = buffer.firstIndex(where: { $0.at >= cutoff }), firstFresh > 0 {
            buffer.removeFirst(firstFresh)
        }
    }
}

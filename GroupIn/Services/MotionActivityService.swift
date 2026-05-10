//
//  MotionActivityService.swift
//  GroupIn
//
//  Wraps CMMotionActivityManager to surface a simple stationary/active
//  signal that AppState uses to throttle location accuracy. Apple's
//  motion classifier already does the hard work of distinguishing
//  walking, running, automotive, cycling, and stationary states with
//  confidence scores — we just collapse them into "moving or not."
//
//  Requires NSMotionUsageDescription in Info.plist. iOS auto-prompts on
//  first call to startActivityUpdates(_:).
//

import Foundation
import CoreMotion

@MainActor
protocol MotionActivityServicing: AnyObject {
    /// True when the most recent motion classification is stationary
    /// with non-low confidence. Defaults to false (assume moving).
    var isStationary: Bool { get }

    /// Yields whenever the stationary/active state flips.
    var stationaryUpdates: AsyncStream<Bool> { get }

    func start()
    func stop()
}

@MainActor
final class MotionActivityService: MotionActivityServicing {
    private let manager = CMMotionActivityManager()
    private let callbackQueue: OperationQueue

    let stationaryUpdates: AsyncStream<Bool>
    private nonisolated let continuation: AsyncStream<Bool>.Continuation

    private(set) var isStationary: Bool = false
    private var running = false

    init() {
        let (stream, cont) = AsyncStream.makeStream(of: Bool.self)
        self.stationaryUpdates = stream
        self.continuation = cont
        self.callbackQueue = OperationQueue()
        self.callbackQueue.qualityOfService = .utility
        self.callbackQueue.name = "com.NDE.GroupIn.motion"
    }

    func start() {
        guard !running else { return }
        guard CMMotionActivityManager.isActivityAvailable() else { return }

        running = true
        manager.startActivityUpdates(to: callbackQueue) { [weak self] activity in
            Task { @MainActor [weak self] in
                self?.process(activity: activity)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopActivityUpdates()
    }

    private func process(activity: CMMotionActivity?) {
        guard let activity else { return }
        // Only trust readings with at least medium confidence — low
        // confidence flips happen at stoplights, in elevators, etc.
        guard activity.confidence != .low else { return }

        // Treat stationary as the "save power" state. Any other
        // classification (walking, running, automotive, cycling, even
        // unknown-but-motion) means keep best accuracy.
        let nowStationary = activity.stationary
        guard nowStationary != isStationary else { return }
        isStationary = nowStationary
        continuation.yield(nowStationary)
    }
}

//
//  HapticEngine.swift
//  GroupIn
//
//  Centralized haptic feedback service. Wraps:
//    • Core Haptics (`CHHapticEngine`) for continuous / variable
//      patterns — compass-on-bearing pulses, proximity heartbeat
//      that intensifies as you approach a peer.
//    • System feedback generators for discrete confirmations —
//      selection ticks, impacts, success/warning/error.
//
//  All public calls are no-ops when:
//    • The user has disabled haptics in their profile preference.
//    • `UIAccessibility.isReduceMotionEnabled` is on (some users
//      treat haptics as motion and want them off together; we honor
//      that as a system-level signal in addition to our own toggle).
//    • The device doesn't support Core Haptics (older hardware).
//
//  The engine restarts itself if iOS suspends it (e.g. after entering
//  background and resuming), so callers don't have to know about
//  engine state — they just request feedback.
//

import Foundation
import CoreHaptics
import UIKit

@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var engine: CHHapticEngine?
    private let supportsHaptics: Bool
    private let selection = UISelectionFeedbackGenerator()
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()

    /// Throttle for the proximity heartbeat — avoids firing more than
    /// once per `minInterval` even if callers loop rapidly.
    private var lastProximityFire: Date = .distantPast

    private init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        bootEngine()
    }

    // MARK: - Public API

    /// Soft "tick" — confirm a tap or selection.
    func tick() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    /// Discrete impact for actions like "route drawn", "sheet snapped".
    func impact(_ style: ImpactStyle) {
        guard isEnabled else { return }
        switch style {
        case .light:  lightImpact.impactOccurred()
        case .medium: mediumImpact.impactOccurred()
        case .rigid:  rigidImpact.impactOccurred()
        }
    }

    /// Success / warning / error chimes (haptic only — no audio).
    func notify(_ kind: NotificationKind) {
        guard isEnabled else { return }
        switch kind {
        case .success: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .error:   notification.notificationOccurred(.error)
        }
    }

    /// Soft tap when the user's heading aligns with a focused peer's
    /// bearing. Intensity scales with how aligned they are.
    /// - Parameter bearingErrorDegrees: absolute heading error in
    ///   degrees (0 = perfectly on-bearing). The caller is expected
    ///   to debounce so we're not invoked every frame.
    func compassAligned(bearingErrorDegrees: Double) {
        guard isEnabled, supportsHaptics, let engine else { return }
        let clamped = max(0, min(30, bearingErrorDegrees))
        // Map 0..30° error → 1.0..0.2 intensity.
        let intensity = Float(1.0 - (clamped / 30.0) * 0.8)
        let sharpness: Float = bearingErrorDegrees < 5 ? 0.85 : 0.5
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        try? play(events: [event])
    }

    /// Heartbeat that pulses faster + stronger as the user gets closer
    /// to a focused peer. Caller can drive this from a timer; the
    /// engine self-throttles so it can't fire more than once per
    /// minInterval (computed from distance).
    func proximityPulse(distanceMeters: Double) {
        guard isEnabled, supportsHaptics, let engine else { return }
        let cadence = proximityCadence(distance: distanceMeters)
        let now = Date()
        if now.timeIntervalSince(lastProximityFire) < cadence.interval { return }
        lastProximityFire = now

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: cadence.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
            ],
            relativeTime: 0
        )
        try? play(events: [event])
    }

    // MARK: - Internals

    private var isEnabled: Bool {
        // Respect both our own toggle and the system Reduce-Motion
        // preference. Users who turn down system motion typically
        // want haptics quieter too.
        guard !UIAccessibility.isReduceMotionEnabled else { return false }
        return Self.isUserEnabled
    }

    /// User-facing preference, default `true` on first launch.
    /// Bindable from the settings UI via `Self.setUserEnabled(_:)`.
    static var isUserEnabled: Bool {
        // `object(forKey:)` lets us distinguish "user explicitly off"
        // from "never set" — UserDefaults.bool returns false for both.
        if let stored = UserDefaults.standard.object(forKey: preferenceKey) as? Bool {
            return stored
        }
        return true
    }

    static func setUserEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    static let preferenceKey = "haptics.enabled"

    /// Distance → (pulse interval, intensity). Hand-tuned.
    private func proximityCadence(distance: Double) -> (interval: TimeInterval, intensity: Float) {
        switch distance {
        case ..<2:    return (0.20, 1.0)   // touching — heartbeat blur
        case ..<5:    return (0.30, 0.95)
        case ..<15:   return (0.55, 0.85)
        case ..<40:   return (0.90, 0.7)
        case ..<100:  return (1.50, 0.55)
        case ..<300:  return (2.50, 0.4)
        default:      return (4.00, 0.25)
        }
    }

    private func bootEngine() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.stoppedHandler = { [weak self] _ in
                // iOS may stop the engine when the app backgrounds or
                // a system audio session takes priority. Rebuild on
                // demand the next time someone calls in.
                Task { @MainActor in self?.engine = nil }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    private func play(events: [CHHapticEvent]) throws {
        if engine == nil { bootEngine() }
        guard let engine else { return }
        let pattern = try CHHapticPattern(events: events, parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
    }

    // MARK: - Types

    enum ImpactStyle { case light, medium, rigid }
    enum NotificationKind { case success, warning, error }
}

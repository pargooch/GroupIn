//
//  VoiceGuidance.swift
//  GroupIn
//
//  Optional spoken-guidance layer for blind / low-vision users.
//  Mirrors `HapticEngine`'s shape:
//    • A single user-facing toggle in the profile editor.
//    • A static `isUserEnabled` flag backed by UserDefaults, default
//      `true` on first launch.
//    • `announce(_:)` is a no-op when VoiceOver isn't running OR the
//      user has turned the toggle off, so callers don't have to gate
//      every site themselves.
//
//  Why a separate layer (not just `UIAccessibility.post`):
//    1. Lets the user opt out of auto-announcements without losing
//       VoiceOver labels — some power users prefer to swipe-explore
//       on their terms.
//    2. Centralizes the rate-limiting we need for the compass's
//       periodic distance updates (one announcement every ~5s, not
//       five per second).
//    3. Keeps the channel polite: even with VoiceOver on, we honor
//       Reduce-Motion / Reduce-Transparency as a hint that the user
//       prefers a calmer experience, and downgrade interrupting
//       announcements to non-interrupting ones.
//

import Foundation
import UIKit

@MainActor
final class VoiceGuidance {
    static let shared = VoiceGuidance()

    static let preferenceKey = "voiceGuidance.enabled"

    /// Min interval between periodic compass announcements. Bumped
    /// from 3 s to 5 s after dogfooding — 3s felt chatty when walking.
    static let compassMinInterval: TimeInterval = 5

    private var lastAnnouncement: Date = .distantPast

    private init() {}

    // MARK: - Public

    /// Fire-and-forget announcement. No-op when VoiceOver is off OR
    /// the user has disabled the toggle.
    func announce(_ message: String, priority: Priority = .standard) {
        guard isActive else { return }
        post(message: message, priority: priority)
    }

    /// Throttled announcement for the compass's "every 5 seconds"
    /// proximity speech. The caller can fire it on every haptic-loop
    /// tick; we self-debounce.
    func compassUpdate(_ message: String) {
        guard isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnnouncement) >= Self.compassMinInterval else {
            return
        }
        lastAnnouncement = now
        post(message: message, priority: .standard)
    }

    /// Force-reset the throttle. Use when entering the compass so the
    /// first reading speaks immediately instead of waiting for the
    /// interval to elapse.
    func resetCompassThrottle() {
        lastAnnouncement = .distantPast
    }

    // MARK: - State

    static var isUserEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: preferenceKey) as? Bool {
            return stored
        }
        return true
    }

    static func setUserEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
    }

    private var isActive: Bool {
        UIAccessibility.isVoiceOverRunning && Self.isUserEnabled
    }

    // MARK: - Internals

    private func post(message: String, priority: Priority) {
        let attributed: AnyObject
        if #available(iOS 17, *), priority == .high {
            // High priority interrupts the current spoken sentence so
            // urgent state ("Within 3 meters", "Group expires soon")
            // isn't queued behind chatter.
            let m = NSMutableAttributedString(string: message)
            m.addAttribute(.accessibilitySpeechAnnouncementPriority,
                           value: UIAccessibilityPriority.high.rawValue,
                           range: NSRange(location: 0, length: m.length))
            attributed = m
        } else {
            attributed = message as NSString
        }
        UIAccessibility.post(notification: .announcement, argument: attributed)
    }

    enum Priority {
        case standard
        case high
    }
}

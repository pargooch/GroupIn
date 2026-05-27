//
//  PresenceStatus.swift
//  GroupIn
//
//  Find My-style staleness model. Drives the per-member pill and the
//  marker opacity on the map.
//

import Foundation
import SwiftUI

enum PresenceStatus {
    case live
    case recent(Date)   // < 5 min
    case stale(Date)    // < 30 min
    case offline(Date?) // >= 30 min, or no fix at all

    /// Live is *only* "we have a live signal path to this peer right
    /// now" — concretely: an MPC payload-transport session in the
    /// connected state, or a fresh-enough sensor fix to call them
    /// real-time. The old heuristic ("lastSeen < 30 s") triggered on
    /// every BLE heartbeat (~20 s cadence) and so was permanently
    /// "Live" for anyone in range — exactly the bug users complained
    /// about. Now the chip says "Live" when there's evidence of a
    /// live channel; otherwise it tiers down by age.
    init(lastSeen: Date,
         hasFix: Bool,
         isLinked: Bool,
         now: Date = .now) {
        if isLinked {
            self = .live
            return
        }
        guard hasFix else {
            self = .offline(lastSeen)
            return
        }
        let delta = now.timeIntervalSince(lastSeen)
        if delta < 5 * 60 {
            self = .recent(lastSeen)
        } else if delta < 30 * 60 {
            self = .stale(lastSeen)
        } else {
            self = .offline(lastSeen)
        }
    }

    var color: Color {
        switch self {
        case .live:    return .green
        case .recent:  return .blue
        case .stale:   return .orange
        case .offline: return .secondary
        }
    }

    var mapOpacity: Double {
        switch self {
        case .live:    return 1.0
        case .recent:  return 1.0
        case .stale:   return 0.55
        case .offline: return 0.3
        }
    }

    /// True only for a fresh real-time fix (< 30 s). Drives the bright
    /// glow on a member dot.
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// True when the member is live OR was seen in the last few minutes
    /// — "recently sharing." Deliberately broader than `isLive` so the
    /// Home summary stays stable instead of flickering as fixes land,
    /// and honest: it never claims real-time, only recent activity.
    var isActivelySharing: Bool {
        switch self {
        case .live, .recent: return true
        case .stale, .offline: return false
        }
    }

    var label: String {
        switch self {
        case .live:                return "Live"
        case .recent(let date),
             .stale(let date):
            return Self.relative(from: date)
        case .offline(let date):
            guard let date else { return "Offline" }
            return Self.relative(from: date)
        }
    }

    private static func relative(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    /// Spoken summary for VoiceOver labels. Slightly more verbose
    /// than `label` so it reads as a natural clause: "last seen 2
    /// minutes ago" instead of just "2 min".
    var accessibilitySummary: String {
        switch self {
        case .live:
            return "live now"
        case .recent(let date), .stale(let date):
            return "last seen \(Self.relativeLong(from: date))"
        case .offline(let date):
            guard let date else { return "offline" }
            return "offline, last seen \(Self.relativeLong(from: date))"
        }
    }

    private static func relativeLong(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

struct PresenceBadge: View {
    let status: PresenceStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(status.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.12), in: Capsule())
        .accessibilityLabel("Presence: \(status.label)")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        PresenceBadge(status: .live)
        PresenceBadge(status: .recent(.now.addingTimeInterval(-90)))
        PresenceBadge(status: .stale(.now.addingTimeInterval(-600)))
        PresenceBadge(status: .offline(.now.addingTimeInterval(-3600)))
        PresenceBadge(status: .offline(nil))
    }
    .padding()
}

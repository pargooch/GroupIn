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

    init(lastSeen: Date, hasFix: Bool, now: Date = .now) {
        guard hasFix else {
            self = .offline(lastSeen)
            return
        }
        let delta = now.timeIntervalSince(lastSeen)
        if delta < 30 {
            self = .live
        } else if delta < 5 * 60 {
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

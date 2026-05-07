//
//  GroupCategory.swift
//  GroupIn
//
//  Activity-based categories. They describe what the group is *doing* —
//  the social makeup (friends, family, etc.) is orthogonal and lives
//  in the group name and member identities, not in this enum.
//

import Foundation
import SwiftUI

enum GroupCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case festival
    case trip
    case tour
    case exploring
    case nature
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .festival:  return "Festival & Concert"
        case .trip:      return "Trip"
        case .tour:      return "Tour"
        case .exploring: return "City Exploring"
        case .nature:    return "Nature"
        case .other:     return "Other"
        }
    }

    var subtitle: String {
        switch self {
        case .festival:  return "Concerts, big crowds"
        case .trip:      return "Travel together"
        case .tour:      return "Guided tour or museum"
        case .exploring: return "Walking and sightseeing"
        case .nature:    return "Hiking, camping, outdoors"
        case .other:     return "Something else"
        }
    }

    var systemImage: String {
        switch self {
        case .festival:  return "music.note.list"
        case .trip:      return "airplane"
        case .tour:      return "map.fill"
        case .exploring: return "building.2.fill"
        case .nature:    return "tree.fill"
        case .other:     return "ellipsis.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .festival:  return .pink
        case .trip:      return .blue
        case .tour:      return .brown
        case .exploring: return .teal
        case .nature:    return .green
        case .other:     return .gray
        }
    }

    /// Suggested default expiry length when the user picks this category.
    /// Override-able from the duration picker.
    var defaultDuration: GroupDuration {
        switch self {
        case .festival:  return .twelveHours
        case .trip:      return .oneDay
        case .tour:      return .fourHours
        case .exploring: return .fourHours
        case .nature:    return .twelveHours
        case .other:     return .fourHours
        }
    }
}

//
//  User.swift
//  GroupIn
//

import Foundation
import CoreLocation

/// In-group representation of a person. The `id` is **per-membership** —
/// a fresh UUID is minted every time the local user creates or joins a
/// group, so memberships across groups can't be linked. The display name
/// and avatar are seeded from `LocalProfile` at join time.
struct User: Identifiable, Hashable, Codable {
    let id: UUID
    var displayName: String
    var avatarData: Data?
    var lastSeen: Date
    var coordinate: Coordinate?

    init(id: UUID = UUID(),
         displayName: String,
         avatarData: Data? = nil,
         lastSeen: Date = .now,
         coordinate: Coordinate? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.lastSeen = lastSeen
        self.coordinate = coordinate
    }
}

struct Coordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

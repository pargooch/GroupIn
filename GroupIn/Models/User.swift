//
//  User.swift
//  GroupIn
//

import Foundation
import CoreLocation

struct User: Identifiable, Hashable, Codable {
    let id: UUID
    var displayName: String
    var lastSeen: Date
    var coordinate: Coordinate?

    init(id: UUID = UUID(), displayName: String, lastSeen: Date = .now, coordinate: Coordinate? = nil) {
        self.id = id
        self.displayName = displayName
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

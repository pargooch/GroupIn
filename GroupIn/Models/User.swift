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
    /// Compass heading in degrees clockwise from true north (0 = north,
    /// 90 = east). Nil when the device hasn't produced a valid reading.
    var heading: Double?
    /// NSKeyedArchiver-encoded `NIDiscoveryToken` for UWB precision
    /// finding. Refreshed each time the local user opens the compass
    /// view targeting another peer; nil for devices without UWB
    /// hardware or before a session has started.
    var nearbyToken: Data?
    /// Per-(iCloud-account, group) salted SHA-256 hash. Stored on
    /// this member's record so the owner can copy it into the group's
    /// banlist when removing them. Opaque to other members; not
    /// correlatable across groups. Nil for users not signed into
    /// iCloud (those users can't be banned but also can't use the
    /// CloudKit backend at all, so the gap is benign).
    var banHash: String?

    init(id: UUID = UUID(),
         displayName: String,
         avatarData: Data? = nil,
         lastSeen: Date = .now,
         coordinate: Coordinate? = nil,
         heading: Double? = nil,
         nearbyToken: Data? = nil,
         banHash: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.lastSeen = lastSeen
        self.coordinate = coordinate
        self.heading = heading
        self.nearbyToken = nearbyToken
        self.banHash = banHash
    }

    /// Old persisted Users (without heading / nearbyToken / banHash)
    /// decode as nil for the missing fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.avatarData = try? c.decode(Data.self, forKey: .avatarData)
        self.lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        self.coordinate = try? c.decode(Coordinate.self, forKey: .coordinate)
        self.heading = try? c.decode(Double.self, forKey: .heading)
        self.nearbyToken = try? c.decode(Data.self, forKey: .nearbyToken)
        self.banHash = try? c.decode(String.self, forKey: .banHash)
    }
}

struct Coordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

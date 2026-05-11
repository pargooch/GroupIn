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
    /// Horizontal accuracy (meters, 1-sigma) of `coordinate`. Nil for
    /// records written before the provenance feature shipped — those
    /// render with a generous default bubble until the user publishes
    /// a fresh position.
    var accuracy: Double?
    /// Provenance tag for `coordinate`. Nil for legacy records; treat
    /// missing as effectively `.gps` with unknown accuracy.
    var positionSource: PositionSource?
    /// For `.deadReckoning` positions, when the last real GPS fix was
    /// taken. Receivers use this to decide whether the integrated
    /// estimate is still trustworthy.
    var positionAnchorAt: Date?
    /// For `.interpolatedFromPeer` positions, the peer that did the
    /// computing. Nil otherwise.
    var positionSourcePeerID: UUID?
    /// Latest event cursor this member has acknowledged locally —
    /// published on every heartbeat tick. Other members read it to
    /// determine whether their outgoing events have reached this
    /// device (the "delivered" half of the delivery-dot rendering).
    /// Nil for legacy records and members who haven't heartbeat'd
    /// since the feature shipped.
    var eventCursorCreatedAt: Date?
    var eventCursorID: UUID?

    init(id: UUID = UUID(),
         displayName: String,
         avatarData: Data? = nil,
         lastSeen: Date = .now,
         coordinate: Coordinate? = nil,
         heading: Double? = nil,
         nearbyToken: Data? = nil,
         banHash: String? = nil,
         accuracy: Double? = nil,
         positionSource: PositionSource? = nil,
         positionAnchorAt: Date? = nil,
         positionSourcePeerID: UUID? = nil,
         eventCursor: EventCursor? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.lastSeen = lastSeen
        self.coordinate = coordinate
        self.heading = heading
        self.nearbyToken = nearbyToken
        self.banHash = banHash
        self.accuracy = accuracy
        self.positionSource = positionSource
        self.positionAnchorAt = positionAnchorAt
        self.positionSourcePeerID = positionSourcePeerID
        self.eventCursorCreatedAt = eventCursor?.createdAt
        self.eventCursorID = eventCursor?.id
    }

    /// Materialized event cursor or nil if either field is missing.
    var eventCursor: EventCursor? {
        guard let date = eventCursorCreatedAt, let id = eventCursorID
        else { return nil }
        return EventCursor(createdAt: date, id: id)
    }

    /// Old persisted Users (without heading / nearbyToken / banHash /
    /// the new provenance fields) decode as nil for the missing keys.
    /// Forward-compatible: as we add more optional fields, old
    /// snapshots keep deserializing.
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
        self.accuracy = try? c.decode(Double.self, forKey: .accuracy)
        self.positionSource = try? c.decode(PositionSource.self, forKey: .positionSource)
        self.positionAnchorAt = try? c.decode(Date.self, forKey: .positionAnchorAt)
        self.positionSourcePeerID = try? c.decode(UUID.self, forKey: .positionSourcePeerID)
        self.eventCursorCreatedAt = try? c.decode(Date.self, forKey: .eventCursorCreatedAt)
        self.eventCursorID = try? c.decode(UUID.self, forKey: .eventCursorID)
    }
}

extension User {
    /// Build a `PositionEstimate` from the User's provenance fields.
    /// Returns nil if there's no coordinate (no fix yet). Legacy
    /// records (coordinate present, source nil) materialize as `.gps`
    /// with a high default accuracy — better than the old "just a
    /// dot, no context" rendering.
    var positionEstimate: PositionEstimate? {
        guard let coord = coordinate else { return nil }
        return PositionEstimate(
            coordinate: coord,
            accuracy: accuracy ?? 100,
            source: positionSource ?? .gps,
            anchorAt: positionAnchorAt,
            sourcePeerID: positionSourcePeerID,
            computedAt: lastSeen
        )
    }

    /// Pin-rendering helper: returns the user's position with
    /// `.staleGPS` provenance + inflated accuracy bubble if the last
    /// fix is older than `freshnessWindow` (default 60s). Caller
    /// passes `now` so the calculation is timeline-driven and the
    /// pin can grow its accuracy ring smoothly as time passes
    /// (TimelineView already ticks at 15s; that's enough resolution).
    func renderablePosition(now: Date,
                            freshnessWindow: TimeInterval = 60) -> PositionEstimate? {
        guard let estimate = positionEstimate else { return nil }
        // Already non-GPS (interpolated, hypothetical, dead-reckoned)
        // — those have their own staleness story; don't double-degrade.
        guard estimate.source == .gps else { return estimate }
        let age = now.timeIntervalSince(estimate.computedAt)
        if age > freshnessWindow {
            return estimate.degradedToStale(now: now)
        }
        return estimate
    }
}

struct Coordinate: Hashable, Codable {
    var latitude: Double
    var longitude: Double

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

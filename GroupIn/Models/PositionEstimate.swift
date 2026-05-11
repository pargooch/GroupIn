//
//  PositionEstimate.swift
//  GroupIn
//
//  Every position carries a *receipt*: where the number came from
//  (GPS? a stale fix from an hour ago? someone else's BLE measurement
//  of us?), how confident we are in meters, and when it was computed.
//  Without this, "Alice is at the fountain" looks identical whether
//  it's a fresh GPS pin or a 2-hour-old echo — bad UX and outright
//  dangerous for the "find each other in a crowd" use case.
//
//  This is the foundational type for Path B (provenance) + Path B.2
//  (dead reckoning + hypothetical) + Path C (peer-interpolated). B.1
//  uses `.gps` and `.staleGPS`; the other cases are wired into the
//  schema now so future phases don't need migrations.
//

import Foundation

enum PositionSource: String, Codable, Sendable, Hashable {
    /// Fresh, real-time CoreLocation fix.
    case gps
    /// The last known GPS coordinate, with an accuracy bubble that
    /// grows over time to reflect the user could have walked anywhere
    /// within that radius.
    case staleGPS
    /// (Path B.2) Pedometer + heading integrated from a known GPS
    /// anchor. Loses accuracy over distance; useful indoors or briefly
    /// underground.
    case deadReckoning
    /// (Path C) Another peer with good GPS computed this position
    /// from their bearing/distance to me via BLE/UWB. The peer that
    /// did the computing is recorded in `sourcePeerID`.
    case interpolatedFromPeer
    /// (Path B.2) No real-world anchor yet — the group has agreed on
    /// a relative coordinate frame around a hypothetical origin. The
    /// first GPS fix from any member converts this back into a real
    /// world frame.
    case hypothetical
}

struct PositionEstimate: Codable, Hashable, Sendable {
    var coordinate: Coordinate
    /// Horizontal accuracy in meters (1-sigma). Larger = less confident.
    /// A `.gps` fix from CoreLocation typically reports 5-30m outdoors,
    /// 50-200m indoors. We never collapse this to a fixed value —
    /// rendering layers use it directly to size accuracy bubbles.
    var accuracy: Double
    var source: PositionSource
    /// For `.deadReckoning`: when the last real GPS fix was taken.
    /// Used by consumers to decide whether to keep trusting the
    /// dead-reckoned estimate or display it with extra caution.
    var anchorAt: Date?
    /// For `.interpolatedFromPeer`: the member ID of the peer that
    /// computed this position. Lets the UI surface "estimated by
    /// Alice" labels and lets future de-dup logic ignore self-loops.
    var sourcePeerID: UUID?
    /// When this estimate was computed (vs. when the underlying GPS
    /// fix was taken — that's `anchorAt` for non-GPS sources, or
    /// just `computedAt` for `.gps`).
    var computedAt: Date

    init(coordinate: Coordinate,
         accuracy: Double,
         source: PositionSource,
         anchorAt: Date? = nil,
         sourcePeerID: UUID? = nil,
         computedAt: Date = .now) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.source = source
        self.anchorAt = anchorAt
        self.sourcePeerID = sourcePeerID
        self.computedAt = computedAt
    }
}

extension PositionEstimate {
    /// Convenience constructor for a fresh CoreLocation fix.
    static func gps(_ coordinate: Coordinate,
                    accuracy: Double,
                    at timestamp: Date = .now) -> PositionEstimate {
        PositionEstimate(
            coordinate: coordinate,
            accuracy: accuracy,
            source: .gps,
            computedAt: timestamp
        )
    }

    /// Returns a `.staleGPS` copy with an inflated accuracy bubble
    /// based on how long ago the fix was taken. The growth model
    /// assumes a worst-case walking pace of ~1.4 m/s, capped so the
    /// bubble doesn't take over the entire map for very old fixes.
    func degradedToStale(now: Date = .now,
                         maxBubble: Double = 300) -> PositionEstimate {
        let age = max(0, now.timeIntervalSince(computedAt))
        let inflated = min(maxBubble, accuracy + age * 1.4)
        return PositionEstimate(
            coordinate: coordinate,
            accuracy: inflated,
            source: .staleGPS,
            anchorAt: computedAt,
            sourcePeerID: nil,
            computedAt: now
        )
    }
}

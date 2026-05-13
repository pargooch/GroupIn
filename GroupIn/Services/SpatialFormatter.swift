//
//  SpatialFormatter.swift
//  GroupIn
//
//  Spoken-language formatters for distance and bearing. Used by every
//  surface that needs a VoiceOver-friendly description of a peer's
//  position: list rows, map markers, compass, live announcements.
//
//  Design goals:
//    • Cardinal-direction strings ("northeast", "behind you") — far
//      more intuitive than degrees for a blind user, and natural for
//      sighted users too.
//    • Localizable distance (uses `MeasurementFormatter` so meters /
//      feet are honored per device locale).
//    • Single source of truth — if we change "northeast" to "north-
//      east" later, it changes everywhere.
//

import Foundation
import CoreLocation

enum SpatialFormatter {

    // MARK: - Distance

    /// Spoken form of a distance: "120 meters", "1.5 kilometers".
    /// Honors the device locale (US users get feet/miles).
    static func distance(meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = [.naturalScale, .providedUnit]
        formatter.unitStyle = .long
        formatter.numberFormatter.maximumFractionDigits = meters < 100 ? 0 : 1
        // Switch to the user's preferred unit system without locking
        // us to one. `Locale.current.measurementSystem` is iOS 16+.
        if Locale.current.measurementSystem != .metric {
            formatter.unitOptions = [.naturalScale]
        }
        return formatter.string(from: measurement)
    }

    /// Compact visual form ("120 m", "1.5 km") for tight UI spaces.
    /// Always metric — pair with `accessibilityLabel(...)` that uses
    /// `distance(meters:)` for the spoken form.
    static func compactDistance(meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(Int(meters.rounded())) m"
    }

    // MARK: - Direction

    /// Human direction relative to the user.
    /// - Parameters:
    ///   - bearing: degrees clockwise from true north, me → peer.
    ///   - userHeading: optional compass heading; when present we
    ///     return body-relative phrasing ("ahead of you", "to your
    ///     left"). When nil we fall back to absolute compass
    ///     directions ("north", "northeast").
    static func direction(bearing: Double, userHeading: Double?) -> String {
        if let heading = userHeading {
            return relativeDirection(bearing: bearing, heading: heading)
        }
        return cardinalDirection(bearing: bearing)
    }

    /// Body-relative: rotates the bearing into the user's frame, then
    /// buckets into 8 zones (ahead, ahead-right, right, behind-right,
    /// behind, behind-left, left, ahead-left).
    static func relativeDirection(bearing: Double, heading: Double) -> String {
        let relative = normalize(bearing - heading)
        switch relative {
        case 0..<22.5, 337.5..<360: return "ahead of you"
        case 22.5..<67.5:           return "ahead and to your right"
        case 67.5..<112.5:          return "to your right"
        case 112.5..<157.5:         return "behind and to your right"
        case 157.5..<202.5:         return "behind you"
        case 202.5..<247.5:         return "behind and to your left"
        case 247.5..<292.5:         return "to your left"
        case 292.5..<337.5:         return "ahead and to your left"
        default:                    return "near you"
        }
    }

    /// Absolute compass cardinal/intercardinal.
    static func cardinalDirection(bearing: Double) -> String {
        let b = normalize(bearing)
        switch b {
        case 0..<22.5, 337.5..<360: return "north"
        case 22.5..<67.5:           return "northeast"
        case 67.5..<112.5:          return "east"
        case 112.5..<157.5:         return "southeast"
        case 157.5..<202.5:         return "south"
        case 202.5..<247.5:         return "southwest"
        case 247.5..<292.5:         return "west"
        case 292.5..<337.5:         return "northwest"
        default:                    return "north"
        }
    }

    // MARK: - Composites

    /// "Alex, 120 meters northeast" — for list rows and markers.
    static func peerSummary(name: String,
                            distanceMeters: Double?,
                            bearingDegrees: Double?,
                            userHeading: Double?) -> String {
        var parts: [String] = [name]
        if let d = distanceMeters {
            parts.append(distance(meters: d))
        }
        if let b = bearingDegrees {
            parts.append(direction(bearing: b, userHeading: userHeading))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Great-circle bearing in degrees clockwise from north.
    static func bearingDegrees(from a: CLLocationCoordinate2D,
                               to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return normalize(degrees)
    }
}

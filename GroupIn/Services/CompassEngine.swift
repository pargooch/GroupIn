//
//  CompassEngine.swift
//  GroupIn
//
//  RSSI-gradient bearing for the magical compass. Pairs each recent RSSI
//  sample for a peer with our own position at that time, then runs a
//  small linear regression: `rssi ≈ a*east + b*north + c`. The (a, b)
//  vector is the direction RSSI increases — i.e., toward the peer.
//
//  This is the offline / no-fresh-GPS-position fallback: position-based
//  bearing is preferred when both phones have a recent fix, and the view
//  layer falls back to this when it doesn't.
//

import Foundation

struct CompassEngine {
    private struct PositionSample {
        let time: Date
        let lat: Double
        let lon: Double
    }
    private struct RSSISample {
        let time: Date
        let rssi: Double
    }

    private var positions: [PositionSample] = []
    private var rssis: [UUID: [RSSISample]] = [:]

    private let window: TimeInterval = 30
    private let minPairs: Int = 5
    private let minMovementMetres: Double = 2

    // MARK: - Recording

    mutating func recordPosition(latitude: Double, longitude: Double) {
        let now = Date()
        positions.append(PositionSample(time: now, lat: latitude, lon: longitude))
        prune(now: now)
    }

    mutating func recordRSSI(_ rssi: Double, for memberID: UUID) {
        let now = Date()
        var arr = rssis[memberID] ?? []
        arr.append(RSSISample(time: now, rssi: rssi))
        rssis[memberID] = arr
        prune(now: now)
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        positions.removeAll { $0.time < cutoff }
        for key in rssis.keys {
            rssis[key]?.removeAll { $0.time < cutoff }
            if rssis[key]?.isEmpty == true {
                rssis.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Queries

    /// Most recent RSSI for a peer, or nil if we have no fresh sample.
    func latestRSSI(for memberID: UUID) -> Double? {
        rssis[memberID]?.last?.rssi
    }

    /// Linear-regression gradient toward the peer.
    /// - Returns: bearing in degrees clockwise from true north and an R²
    ///   confidence in [0, 1]. Nil when there's not enough movement,
    ///   not enough samples, or the regression is degenerate.
    func gradientBearing(toMember memberID: UUID) -> (bearing: Double, confidence: Double)? {
        guard let samples = rssis[memberID], samples.count >= minPairs else { return nil }
        guard let ref = positions.last else { return nil }

        let metresPerDegLat = 111_000.0
        let metresPerDegLon = 111_000.0 * cos(ref.lat * .pi / 180)

        // Pair each RSSI with the closest-in-time position.
        var pairs: [(dx: Double, dy: Double, rssi: Double)] = []
        pairs.reserveCapacity(samples.count)
        for sample in samples {
            guard let nearest = positions.min(by: {
                abs($0.time.timeIntervalSince(sample.time))
                    < abs($1.time.timeIntervalSince(sample.time))
            }) else { continue }
            let dx = (nearest.lon - ref.lon) * metresPerDegLon  // east
            let dy = (nearest.lat - ref.lat) * metresPerDegLat  // north
            pairs.append((dx, dy, sample.rssi))
        }
        guard pairs.count >= minPairs else { return nil }

        // Need at least a few metres of movement spread to fit a gradient.
        let xs = pairs.map(\.dx)
        let ys = pairs.map(\.dy)
        let xRange = (xs.max() ?? 0) - (xs.min() ?? 0)
        let yRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard sqrt(xRange * xRange + yRange * yRange) >= minMovementMetres else {
            return nil
        }

        // OLS: rssi = a*dx + b*dy + c
        let n = Double(pairs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        let mr = pairs.map(\.rssi).reduce(0, +) / n

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        var sxr = 0.0, syr = 0.0
        for p in pairs {
            let cx = p.dx - mx
            let cy = p.dy - my
            let cr = p.rssi - mr
            sxx += cx * cx
            syy += cy * cy
            sxy += cx * cy
            sxr += cx * cr
            syr += cy * cr
        }

        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-6 else { return nil }

        let a = (syy * sxr - sxy * syr) / det
        let b = (sxx * syr - sxy * sxr) / det

        let magnitude = sqrt(a * a + b * b)
        guard magnitude > 0.001 else { return nil }

        // (a = east, b = north). atan2(east, north) → bearing clockwise
        // from north, which is what compasses use.
        var bearing = atan2(a, b) * 180 / .pi
        if bearing < 0 { bearing += 360 }

        // R² as confidence
        var ssRes = 0.0, ssTot = 0.0
        for p in pairs {
            let predicted = a * (p.dx - mx) + b * (p.dy - my) + mr
            ssRes += pow(p.rssi - predicted, 2)
            ssTot += pow(p.rssi - mr, 2)
        }
        let r2 = ssTot > 1e-6 ? max(0, 1 - ssRes / ssTot) : 0

        return (bearing, r2)
    }

    /// Distance band derived from raw RSSI (used by the gradient mode of
    /// the compass when no GPS distance is available). Apple's docs are
    /// careful never to claim meter-precision from BLE proximity, and
    /// neither do we.
    nonisolated static func distanceBand(rssi: Double) -> String {
        switch rssi {
        case (-55)...:    return "Close"
        case (-70)..<(-55): return "Nearby"
        case (-85)..<(-70): return "Further off"
        default:          return "Far away"
        }
    }
}

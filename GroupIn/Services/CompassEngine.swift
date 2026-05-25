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
    /// One RSSI sample held in the rolling window. We keep three
    /// dB values per sample so the regression and the diagnostic
    /// strip can each pull what they want without recomputing:
    ///   • `raw`     — exactly what the radio reported.
    ///   • `hampel`  — Hampel-lite smoothed (median substituted when
    ///                 the raw value spikes through a wall/pocket).
    ///   • `ewma`    — exponentially-weighted moving average over the
    ///                 Hampel-smoothed stream. Stable enough to fit a
    ///                 regression against; the OLS uses this field.
    private struct RSSISample {
        let time: Date
        let raw: Double
        let hampel: Double
        let ewma: Double
    }

    /// Outcome of the regression preconditions. Lets the diagnostic
    /// strip surface *why* a bearing isn't available instead of just
    /// "nil". Eyeballing the cascade in `gradientBearing` and
    /// `gradientStatus` should make the mapping obvious.
    enum GradientStatus: Equatable {
        case ready                              // has produced a fit
        case needSamples(have: Int)             // <minPairs RSSI samples in window
        case needPositions                      // no positions recorded at all
        case needMovement(haveMetres: Double)   // positions exist but spread < minMovementMetres
        case singular                           // covariance determinant too small (collinear) — note: 1D fallback handles this so this status is rare
        case degenerate                         // gradient magnitude too small
        /// Majority of paired (local, remote) samples disagreed by
        /// >6 dB. The regression still runs (local values are kept),
        /// but the fit confidence is heavily polluted by multipath
        /// reflections. UI uses this to suggest the user step into
        /// open space.
        case multipathHeavy
    }

    private var positions: [PositionSample] = []
    private var rssis: [UUID: [RSSISample]] = [:]

    /// Parallel buffer of RSSI samples the *peer* reports of us, piped
    /// in via `recordRemoteRSSI` from `mergeBLEPeer`. We pair these
    /// with our own samples in `gradientBearing` to denoise via
    /// bilateral agreement — a value both sides agree on is far less
    /// likely to be a wall reflection or a hand-blocked antenna.
    private var remoteRSSIs: [UUID: [RSSISample]] = [:]

    /// Running EWMA on top of the Hampel filter. Carried across calls
    /// to `recordRSSI` so the smoothing has memory beyond the rolling
    /// buffer — even if a sample falls out of the 30 s window we want
    /// the next one to land on the same smoothed trajectory.
    private var ewmaByMember: [UUID: Double] = [:]
    private let rssiEWMAAlpha: Double = 0.3

    /// Running synthetic position used by `recordStep`. Indoor mode
    /// can't rely on GPS or DR coordinates moving — we project a
    /// fake lat/lon forward by each step's heading × stride and
    /// store that into `positions`. Seeded from the most recent
    /// real position on first call, otherwise starts at (0, 0)
    /// which is fine since the regression only cares about relative
    /// offsets.
    private var syntheticAnchorLat: Double?
    private var syntheticAnchorLon: Double?

    private let window: TimeInterval = 30
    private let minPairs: Int = 3
    private let minMovementMetres: Double = 1

    /// Hampel-lite outlier rejection: when a raw RSSI sample differs
    /// from the running median by more than this many dB *and* arrives
    /// within `obstacleEventInterval` of the previous sample, treat it
    /// as a wall/pocket transition rather than a real distance
    /// change. The smoother substitutes the median for the regression
    /// input — raw is preserved for diagnostics but not fitted.
    private let outlierDeltaDB: Double = 18
    private let obstacleEventInterval: TimeInterval = 0.5

    // MARK: - Recording

    mutating func recordPosition(latitude: Double, longitude: Double) {
        let now = Date()
        positions.append(PositionSample(time: now, lat: latitude, lon: longitude))
        // A real position resets the synthetic anchor so the next step
        // projects from current ground truth rather than the prior
        // synthetic ghost coordinate.
        syntheticAnchorLat = latitude
        syntheticAnchorLon = longitude
        prune(now: now)
    }

    /// Append a synthetic position offset, computed from a step event.
    /// Indoor mode lives off this path: GPS doesn't fire indoors and
    /// DR refuses to project displacement without a GPS anchor, so
    /// the only way to get position spread for the gradient is to
    /// integrate steps × heading ourselves.
    /// - Parameters:
    ///   - at: the step's actual occurrence time. **Critical for the
    ///     regression**: every RSSI sample is later paired with the
    ///     position whose time best matches the sample's. If every
    ///     position in a batch shares `Date()` (the call time) instead
    ///     of the interpolated per-step time, all 5-Hz RSSI samples
    ///     pair with the single latest position → effective spread
    ///     collapses to zero → "need movement" forever. Defaults to
    ///     `Date()` for callers that don't have a per-step timestamp.
    ///   - headingDegrees: bearing clockwise from true north (CLHeading
    ///     `trueHeading` convention). 0 = north, 90 = east.
    ///   - stepLengthMetres: total displacement for this event. For a
    ///     pedometer batch of `n` steps with stride `s`, pass
    ///     `Double(n) * s`.
    mutating func recordStep(at time: Date = Date(),
                             headingDegrees: Double,
                             stepLengthMetres: Double) {
        guard stepLengthMetres > 0 else { return }
        let baseLat = syntheticAnchorLat ?? positions.last?.lat ?? 0
        let baseLon = syntheticAnchorLon ?? positions.last?.lon ?? 0

        let headingRad = headingDegrees * .pi / 180
        let north = stepLengthMetres * cos(headingRad)
        let east = stepLengthMetres * sin(headingRad)

        let metresPerDegLat = 111_000.0
        let metresPerDegLon = 111_000.0 * cos(baseLat * .pi / 180)
        let newLat = baseLat + north / metresPerDegLat
        let newLon = baseLon + east / max(metresPerDegLon, 1)

        syntheticAnchorLat = newLat
        syntheticAnchorLon = newLon

        positions.append(PositionSample(time: time, lat: newLat, lon: newLon))
        // Prune relative to actual wall-clock now, not the step's
        // (possibly historical) timestamp — we want to keep the
        // 30 s window honest even when handleStepBatch is
        // back-filling positions for older interpolated times.
        prune(now: Date())
    }

    mutating func recordRSSI(_ rawRSSI: Double, for memberID: UUID) {
        let now = Date()
        var arr = rssis[memberID] ?? []

        // Filter 1: Hampel-lite. If the new sample diverges sharply
        // from the recent median *and* arrives suspiciously fast,
        // substitute the median. Bodies, pockets, and walls produce
        // exactly this signature; the regression should track the
        // smoother curve, not the obstacle artifact.
        let recent = arr.suffix(4).map(\.hampel) + [rawRSSI]
        let median = Self.median(of: recent)
        let dt = arr.last.map { now.timeIntervalSince($0.time) } ?? .infinity
        let hampelSmoothed: Double
        if abs(rawRSSI - median) > outlierDeltaDB,
           dt < obstacleEventInterval {
            hampelSmoothed = median
        } else {
            hampelSmoothed = rawRSSI
        }

        // Filter 2: EWMA on top of Hampel. The regression fits against
        // this — a low-pass second stage damps the rapid breathing
        // that survives Hampel (Hampel only catches outliers, not
        // noise in the bulk of the distribution).
        let previousEWMA = ewmaByMember[memberID]
        let ewmaValue: Double
        if let previousEWMA {
            ewmaValue = rssiEWMAAlpha * hampelSmoothed
                + (1 - rssiEWMAAlpha) * previousEWMA
        } else {
            // First sample for this member — bootstrap to the Hampel
            // value so the smoother starts from a real number rather
            // than zero (which would drag the first 5–10 samples
            // toward the noise floor).
            ewmaValue = hampelSmoothed
        }
        ewmaByMember[memberID] = ewmaValue

        arr.append(RSSISample(time: now,
                              raw: rawRSSI,
                              hampel: hampelSmoothed,
                              ewma: ewmaValue))
        rssis[memberID] = arr
        prune(now: now)
    }

    /// Record an RSSI sample the *peer* reports of us. Same 30 s
    /// rolling window as the local buffer; same Hampel / EWMA
    /// smoothing chain runs against `remoteRSSIs` so the bilateral
    /// fusion in `gradientBearing` compares like-for-like values.
    mutating func recordRemoteRSSI(_ rawRSSI: Double, fromMemberID memberID: UUID) {
        let now = Date()
        var arr = remoteRSSIs[memberID] ?? []

        // Mirror the local-side Hampel filter against the remote
        // buffer. Different physical antenna, same artifact shape:
        // a sample 18 dB off the recent median within 500 ms means
        // a body got in the way of the *peer's* radio, not us.
        let recent = arr.suffix(4).map(\.hampel) + [rawRSSI]
        let median = Self.median(of: recent)
        let dt = arr.last.map { now.timeIntervalSince($0.time) } ?? .infinity
        let hampelSmoothed: Double
        if abs(rawRSSI - median) > outlierDeltaDB,
           dt < obstacleEventInterval {
            hampelSmoothed = median
        } else {
            hampelSmoothed = rawRSSI
        }

        // EWMA is per-direction so the remote stream gets its own
        // memory — we don't want the peer's noisy first sample to
        // perturb the local smoother and vice versa.
        let previousEWMA = remoteEwmaByMember[memberID]
        let ewmaValue: Double
        if let previousEWMA {
            ewmaValue = rssiEWMAAlpha * hampelSmoothed
                + (1 - rssiEWMAAlpha) * previousEWMA
        } else {
            ewmaValue = hampelSmoothed
        }
        remoteEwmaByMember[memberID] = ewmaValue

        arr.append(RSSISample(time: now,
                              raw: rawRSSI,
                              hampel: hampelSmoothed,
                              ewma: ewmaValue))
        remoteRSSIs[memberID] = arr
        prune(now: now)
    }

    /// EWMA memory for the *remote* RSSI stream, kept separate from
    /// `ewmaByMember` so each direction's smoother carries its own
    /// state. Both streams independently low-pass to the same target.
    private var remoteEwmaByMember: [UUID: Double] = [:]

    /// Median of a small array. Cheap O(n log n) — sample windows are
    /// 3–5 entries so the sort cost is negligible.
    private static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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
        for key in remoteRSSIs.keys {
            remoteRSSIs[key]?.removeAll { $0.time < cutoff }
            if remoteRSSIs[key]?.isEmpty == true {
                remoteRSSIs.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Queries

    /// Most recent RSSI for a peer, or nil if we have no fresh sample.
    /// Returns the EWMA-smoothed value because every downstream consumer
    /// (`distanceBand`, the "Speak distance" VoiceOver helper) wants a
    /// stable read, not the raw breathing noise.
    func latestRSSI(for memberID: UUID) -> Double? {
        rssis[memberID]?.last?.ewma
    }

    /// Number of position samples currently in the rolling window.
    /// Exposed for the indoor diagnostic strip: positions == 0 while
    /// RSSI samples flood in means the regression has nothing to
    /// anchor against and bearing will always be nil.
    var positionSampleCount: Int { positions.count }

    /// Spread of the position window in metres along the dominant axis.
    /// Zero when fewer than two positions exist or when all positions
    /// sit on the same point. The regression needs spread ≥
    /// `minMovementMetres` to fit a direction.
    var positionSpreadMetres: Double {
        guard positions.count >= 2 else { return 0 }
        let metresPerDegLat = 111_000.0
        let refLat = positions.last?.lat ?? 0
        let metresPerDegLon = 111_000.0 * cos(refLat * .pi / 180)
        let xs = positions.map { $0.lon * metresPerDegLon }
        let ys = positions.map { $0.lat * metresPerDegLat }
        let xRange = (xs.max() ?? 0) - (xs.min() ?? 0)
        let yRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        return sqrt(xRange * xRange + yRange * yRange)
    }

    /// Count of RSSI samples we hold for a specific peer in the rolling
    /// window. Distinct from the BLE service's session-total counter —
    /// this one is what the regression actually fits against.
    func rssiSampleCount(for memberID: UUID) -> Int {
        rssis[memberID]?.count ?? 0
    }

    /// Time-interpolated position lookup. Positions are appended in
    /// chronological order (every caller — GPS fix, DR estimate,
    /// per-step recordStep with explicit timestamps — produces
    /// monotonic times in practice). For a target time `t`:
    ///   - before the first position → first position
    ///   - after the last position → last position
    ///   - between two positions → linear interpolation
    /// Returns `(lat, lon)` so the caller can convert to metres.
    /// Without this the regression pairs every recent 5-Hz RSSI
    /// sample with the *single* latest position, collapsing the
    /// effective spread to zero even when many positions exist.
    private func positionInterpolated(at t: Date) -> (lat: Double, lon: Double)? {
        guard !positions.isEmpty else { return nil }
        if positions.count == 1 || t <= positions[0].time {
            return (positions[0].lat, positions[0].lon)
        }
        if let last = positions.last, t >= last.time {
            return (last.lat, last.lon)
        }
        // Linear scan for the bracketing pair. Position buffer is
        // typically <50 entries in a 30 s window so linear is fine.
        for i in 0..<(positions.count - 1) {
            let a = positions[i]
            let b = positions[i + 1]
            if t >= a.time && t <= b.time {
                let span = b.time.timeIntervalSince(a.time)
                if span <= 0 { return (a.lat, a.lon) }
                let frac = t.timeIntervalSince(a.time) / span
                return (
                    a.lat + (b.lat - a.lat) * frac,
                    a.lon + (b.lon - a.lon) * frac
                )
            }
        }
        return (positions[positions.count - 1].lat,
                positions[positions.count - 1].lon)
    }

    /// Granular status of the gradient regression for the given peer.
    /// Runs the same precondition cascade as `gradientBearing` but
    /// returns the failure reason instead of nil — driving the
    /// indoor diagnostic strip's "what's missing" line.
    func gradientStatus(toMember memberID: UUID) -> GradientStatus {
        let samples = rssis[memberID] ?? []
        guard samples.count >= minPairs else {
            return .needSamples(have: samples.count)
        }
        guard !positions.isEmpty else { return .needPositions }
        guard let ref = positions.last else { return .needPositions }

        let metresPerDegLat = 111_000.0
        let metresPerDegLon = 111_000.0 * cos(ref.lat * .pi / 180)

        var pairs: [(dx: Double, dy: Double)] = []
        for sample in samples {
            guard let interp = positionInterpolated(at: sample.time) else { continue }
            let dx = (interp.lon - ref.lon) * metresPerDegLon
            let dy = (interp.lat - ref.lat) * metresPerDegLat
            pairs.append((dx, dy))
        }
        guard pairs.count >= minPairs else {
            return .needSamples(have: pairs.count)
        }

        let xs = pairs.map(\.dx)
        let ys = pairs.map(\.dy)
        let xRange = (xs.max() ?? 0) - (xs.min() ?? 0)
        let yRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        let spread = sqrt(xRange * xRange + yRange * yRange)
        guard spread >= minMovementMetres else {
            return .needMovement(haveMetres: spread)
        }

        // Bilateral disagreement check — if the majority of pairs
        // we could match against a remote sample disagree by > 6 dB,
        // the environment is producing too much multipath for the
        // gradient to mean anything. Bearing might still resolve
        // (gradientBearing keeps the local values) but we flag it.
        if multipathHeavy(forMember: memberID) {
            return .multipathHeavy
        }

        // Singular / degenerate decisions need the full regression —
        // re-run it (cheaply, the 30 s window has ~150 samples max)
        // and return ready or the corresponding failure.
        guard let result = gradientBearing(toMember: memberID) else {
            return .singular
        }
        // Magnitude check is the only remaining post-fit failure;
        // gradientBearing returns nil for both singular *and*
        // degenerate but with 1D fallback covering the singular
        // case, a nil here points at degenerate.
        _ = result
        return .ready
    }

    /// Quick majority-vote check against the bilateral RSSI buffer.
    /// Returns true when more than half of matchable local samples
    /// are >6 dB out from the peer's measurement — i.e., the link
    /// is dominated by reflections rather than line-of-sight.
    private func multipathHeavy(forMember memberID: UUID) -> Bool {
        let locals = rssis[memberID] ?? []
        let remotes = remoteRSSIs[memberID] ?? []
        guard !locals.isEmpty, !remotes.isEmpty else { return false }
        var matched = 0
        var suspect = 0
        for sample in locals {
            guard let mate = Self.nearestInTime(to: sample.time,
                                                in: remotes,
                                                tolerance: 0.2) else { continue }
            matched += 1
            if abs(sample.ewma - mate.ewma) > 6 { suspect += 1 }
        }
        guard matched >= minPairs else { return false }
        return Double(suspect) > Double(matched) * 0.5
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

        // Build pairs of (position offset, fused RSSI, age, optional
        // multipath flag). Local EWMA is the baseline; if the peer
        // gave us a co-temporal sample we fuse the two per the
        // bilateral-agreement rules.
        struct Pair {
            let dx: Double
            let dy: Double
            let rssi: Double
            let age: Double            // seconds since sample.time
            let localVariance: Double  // 5-sample neighbourhood variance
            let multipathSuspect: Bool // > 6 dB disagreement with peer
        }
        let now = Date()
        let remoteSamples = remoteRSSIs[memberID] ?? []
        var pairs: [Pair] = []
        pairs.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            // Time-interpolated position — see `positionInterpolated`.
            // Picking the nearest single position collapses all
            // recent RSSI samples onto the latest position, killing
            // the regression's effective spread.
            guard let interp = positionInterpolated(at: sample.time) else {
                continue
            }
            let dx = (interp.lon - ref.lon) * metresPerDegLon  // east
            let dy = (interp.lat - ref.lat) * metresPerDegLat  // north

            // Bilateral fusion: pair with the closest-in-time remote
            // sample inside ±200 ms. The 200 ms tolerance gives us
            // wiggle for clock skew between the two devices' presence
            // packets without admitting samples taken under
            // meaningfully different geometry.
            let mate = Self.nearestInTime(to: sample.time,
                                          in: remoteSamples,
                                          tolerance: 0.2)
            let localVar = Self.localVariance(around: index, in: samples)
            let (fused, suspect): (Double, Bool)
            if let mate {
                let disagreement = abs(sample.ewma - mate.ewma)
                if disagreement <= 2 {
                    fused = (sample.ewma + mate.ewma) / 2
                    suspect = false
                } else if disagreement <= 6 {
                    // Pick whichever side has the calmer recent
                    // neighbourhood — that side likely has the
                    // less-reflected antenna in this instant.
                    let remoteIdx = remoteSamples.firstIndex { $0.time == mate.time } ?? 0
                    let remoteVar = Self.localVariance(around: remoteIdx,
                                                       in: remoteSamples)
                    fused = localVar <= remoteVar ? sample.ewma : mate.ewma
                    suspect = false
                } else {
                    // Big disagreement — keep our local read but
                    // flag the pair so WLS downweights it.
                    fused = sample.ewma
                    suspect = true
                }
            } else {
                fused = sample.ewma
                suspect = false
            }

            pairs.append(Pair(
                dx: dx,
                dy: dy,
                rssi: fused,
                age: now.timeIntervalSince(sample.time),
                localVariance: localVar,
                multipathSuspect: suspect
            ))
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

        // Per-pair leverage: spread-out points get more say. Compute
        // each pair's average distance to its three nearest neighbours
        // in (dx, dy) space, then normalize by the mean of those
        // averages so the weight is dimensionless and ≈1 for typical
        // pairs, > 1 for outliers in the *position* sense (which is
        // what we want — those are the points that pin the gradient).
        let positionsForLeverage = pairs.map { ($0.dx, $0.dy) }
        let avgNearestPerPair = positionsForLeverage.indices.map { i in
            Self.avgDistanceToNearest(index: i,
                                      among: positionsForLeverage,
                                      k: 3)
        }
        let leverageMean = avgNearestPerPair.reduce(0, +)
            / Double(max(avgNearestPerPair.count, 1))
        let safeLeverageMean = max(leverageMean, 1e-6)

        // Compose per-pair weights: recency × variance × leverage.
        // Multipath-suspect pairs additionally take a 0.25 multiplier
        // so the WLS still sees them (they may anchor the centroid)
        // but doesn't let them swing the bearing.
        var weights: [Double] = []
        weights.reserveCapacity(pairs.count)
        for (i, p) in pairs.enumerated() {
            let wRecency = exp(-p.age / 10.0)
            let wVariance = 1.0 / max(p.localVariance, 1.0)
            let wLeverage = avgNearestPerPair[i] / safeLeverageMean
            var w = wRecency * wVariance * wLeverage
            if p.multipathSuspect { w *= 0.25 }
            weights.append(w)
        }

        // Weighted OLS: rssi = a*dx + b*dy + c.
        let W = weights.reduce(0, +)
        guard W > 0 else { return nil }
        var mx = 0.0, my = 0.0, mr = 0.0
        for (i, p) in pairs.enumerated() {
            mx += weights[i] * p.dx
            my += weights[i] * p.dy
            mr += weights[i] * p.rssi
        }
        mx /= W; my /= W; mr /= W

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        var sxr = 0.0, syr = 0.0
        for (i, p) in pairs.enumerated() {
            let cx = p.dx - mx
            let cy = p.dy - my
            let cr = p.rssi - mr
            let w = weights[i]
            sxx += w * cx * cx
            syy += w * cy * cy
            sxy += w * cx * cy
            sxr += w * cx * cr
            syr += w * cy * cr
        }

        let det = sxx * syy - sxy * sxy
        let a: Double
        let b: Double
        let r2Multiplier: Double  // 1.0 for 2D fit, 0.5 for 1D fallback

        if abs(det) < 1e-6 {
            // Collinear positions — the 2x2 matrix is singular and
            // OLS in two unknowns is ill-posed. Reduce to a 1D
            // regression along the principal direction of the
            // (dx, dy) cloud. For det≈0, the covariance matrix has
            // one dominant eigenvalue; its eigenvector is the
            // direction every sample lies along.
            let (ux, uy) = Self.principalAxis(sxx: sxx, syy: syy, sxy: sxy)
            // Project each pair onto the principal axis. The result
            // is a scalar `s` measuring position along the line.
            var ssWeighted = 0.0
            var srWeighted = 0.0
            for (i, p) in pairs.enumerated() {
                let s = (p.dx - mx) * ux + (p.dy - my) * uy
                let r = p.rssi - mr
                ssWeighted += weights[i] * s * s
                srWeighted += weights[i] * s * r
            }
            guard ssWeighted > 1e-6 else { return nil }
            let slope = srWeighted / ssWeighted  // dB per metre
            // Store the slope projected back onto the (east, north)
            // basis. atan2(a, b) will then yield the bearing
            // automatically, and the R² prediction below uses the
            // same `a·dx + b·dy + mr` formula as the 2D branch
            // (since `a·dx + b·dy = slope · (dx·ux + dy·uy) = slope · s`).
            // Sign of slope encodes direction toward higher RSSI:
            // positive → peer is in the +(ux, uy) direction;
            // negative → peer is in the opposite direction.
            a = slope * ux
            b = slope * uy
            // 1D fit is strictly less informative than the 2D one
            // would have been — halve the R² so the UI's confidence
            // band reflects the weaker constraint.
            r2Multiplier = 0.5
        } else {
            a = (syy * sxr - sxy * syr) / det
            b = (sxx * syr - sxy * sxr) / det
            r2Multiplier = 1.0
        }

        let magnitude = sqrt(a * a + b * b)
        guard magnitude > 0.001 else { return nil }

        // (a = east, b = north). atan2(east, north) → bearing clockwise
        // from north, which is what compasses use.
        var bearing = atan2(a, b) * 180 / .pi
        if bearing < 0 { bearing += 360 }

        // Weighted R² as confidence. With (a, b) carrying the slope
        // in both branches, the same prediction formula works for
        // 1D and 2D — see the principal-axis comment above.
        var ssRes = 0.0, ssTot = 0.0
        for (i, p) in pairs.enumerated() {
            let predicted = a * (p.dx - mx) + b * (p.dy - my) + mr
            let w = weights[i]
            ssRes += w * pow(p.rssi - predicted, 2)
            ssTot += w * pow(p.rssi - mr, 2)
        }
        let r2 = ssTot > 1e-6 ? max(0, 1 - ssRes / ssTot) : 0

        return (bearing, r2 * r2Multiplier)
    }

    // MARK: - Helpers

    /// Variance of the 5 RSSI EWMA values nearest in time to `index`
    /// in `samples`. Used as a per-pair denoising weight: tight,
    /// stable readings get more pull on the regression.
    private static func localVariance(around index: Int,
                                      in samples: [RSSISample]) -> Double {
        guard !samples.isEmpty else { return 1 }
        let half = 2
        let lo = max(0, index - half)
        let hi = min(samples.count - 1, index + half)
        let slice = samples[lo...hi].map(\.ewma)
        guard slice.count > 1 else { return 1 }
        let mean = slice.reduce(0, +) / Double(slice.count)
        let varSum = slice.reduce(0) { $0 + pow($1 - mean, 2) }
        return varSum / Double(slice.count)
    }

    /// Average distance from `points[index]` to its `k` nearest
    /// neighbours in the (x, y) cloud. Drives the leverage weight —
    /// spread-out points get more pull.
    private static func avgDistanceToNearest(index: Int,
                                              among points: [(Double, Double)],
                                              k: Int) -> Double {
        let self_ = points[index]
        var others = points.enumerated().compactMap { (i, p) -> Double? in
            guard i != index else { return nil }
            let dx = p.0 - self_.0
            let dy = p.1 - self_.1
            return sqrt(dx * dx + dy * dy)
        }
        guard !others.isEmpty else { return 0 }
        others.sort()
        let take = others.prefix(min(k, others.count))
        return take.reduce(0, +) / Double(take.count)
    }

    /// Principal direction (unit vector) of a 2x2 covariance matrix
    /// expressed as its weighted second moments. Returns the
    /// eigenvector corresponding to the LARGER eigenvalue — the axis
    /// along which the cloud has the most variance, which is what
    /// the 1D fallback projects onto.
    private static func principalAxis(sxx: Double,
                                       syy: Double,
                                       sxy: Double) -> (Double, Double) {
        // 2x2 symmetric matrix [[sxx, sxy], [sxy, syy]]. Eigenvalues:
        //   λ = (sxx + syy)/2 ± sqrt(((sxx - syy)/2)² + sxy²)
        // We want the eigenvector for the larger eigenvalue.
        let trace = sxx + syy
        let diff = (sxx - syy) / 2
        let discrim = sqrt(diff * diff + sxy * sxy)
        let lambda = trace / 2 + discrim
        // Eigenvector solves (sxx - λ) ux + sxy uy = 0.
        let ux: Double
        let uy: Double
        if abs(sxy) > 1e-9 {
            ux = sxy
            uy = lambda - sxx
        } else if sxx >= syy {
            // Already axis-aligned along x.
            ux = 1
            uy = 0
        } else {
            ux = 0
            uy = 1
        }
        let mag = sqrt(ux * ux + uy * uy)
        guard mag > 1e-9 else { return (1, 0) }
        return (ux / mag, uy / mag)
    }

    /// Closest-in-time `RSSISample` in `pool` to `target`, within
    /// `tolerance` seconds either side. Used by both the bilateral
    /// pairing in `gradientBearing` and the multipath-heavy check
    /// in `gradientStatus`.
    private static func nearestInTime(to target: Date,
                                      in pool: [RSSISample],
                                      tolerance: TimeInterval) -> RSSISample? {
        var best: RSSISample?
        var bestDelta = tolerance
        for sample in pool {
            let delta = abs(sample.time.timeIntervalSince(target))
            if delta <= bestDelta {
                bestDelta = delta
                best = sample
            }
        }
        return best
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

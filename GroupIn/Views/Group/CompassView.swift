//
//  CompassView.swift
//  GroupIn
//
//  Full-screen "Finding X" experience. A neon, wearable-inspired
//  directional compass:
//
//    • A glowing circular orb in the center holding a thin-line
//      geometric gemstone glyph (cyan-blue, like a reactor core).
//    • A ring of 24 small dots orbiting the orb, illuminated by
//      proximity to the friend's bearing — the closest dot to the
//      direction glows brightest, neighbours fade off via cosine
//      falloff.
//    • Friend avatar floating above the orb in their assigned
//      member color, distance + transport mode badge below.
//
//  Data sources are unchanged from the previous iteration —
//  `arrowReading()` still resolves UWB → GPS → BLE-gradient in
//  that priority order. Only the visual layer is new.
//

import SwiftUI
import CoreLocation

struct CompassView: View {
    let memberID: UUID
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Tracks the previous phone-frame bearing error so we fire an
    /// alignment haptic only when crossing INTO a tighter zone (e.g.
    /// from 20° down to 15°), not on every sample.
    @State private var lastBearingError: Double = 180
    /// Last distance announced to VoiceOver. Used to fire one
    /// announcement per threshold crossing without chatter.
    @State private var lastAnnouncedDistance: Double = .greatestFiniteMagnitude
    /// Tracks whether VoiceOver has already heard "Aligned with X"
    /// for this acquisition. Reset when alignment is lost.
    @State private var announcedAligned: Bool = false
    @State private var seekerMode: SeekerMode = .auto

    /// Cyan-blue tone used for the orb ring + diamond gem. Fixed
    /// across all members — it's the "GroupIn brand" element of the
    /// compass. Per-member color is used for the dot ring and the
    /// surrounding accents so each friend's compass still feels
    /// theirs.
    private static let orbAccent = Color(
        red: 0.30, green: 0.92, blue: 1.00  // ~#4DEBFF — electric cyan
    )

    var body: some View {
        let member = currentMember
        let memberColor = Color.memberColor(for: memberID)
        let reading = arrowReading()

        ZStack {
            backdrop(color: memberColor)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                header(member: member, color: memberColor)
                    .padding(.top, 32)

                if seekerMode == .indoor {
                    indoorDiagnosticStrip(memberID: memberID)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 12)

                if let reading {
                    compassDial(reading: reading, memberColor: memberColor)
                        .frame(width: 320, height: 320)
                        .accessibilityHidden(true)
                } else {
                    waitingState(member: member)
                        .frame(width: 320, height: 320)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 8)

                if let reading {
                    distanceBlock(reading: reading, color: memberColor, member: member)
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                }

                doneButton(color: memberColor)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }

            // Invisible VoiceOver layer over the whole compass.
            // Reading this single element gives a blind user the
            // complete picture; custom actions cover the on-demand
            // requests ("speak distance", "speak direction") that
            // the rotor surfaces.
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(compassAccessibilityLabel(reading: reading,
                                                              member: member))
                .accessibilityValue(compassAccessibilityValue(reading: reading))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityAction(named: "Speak distance") {
                    if let m = reading?.metres {
                        announce("\(member?.displayName ?? "Friend") is \(SpatialFormatter.distance(meters: m)) away.")
                    } else {
                        announce("Distance is not available right now.")
                    }
                }
                .accessibilityAction(named: "Speak direction") {
                    if let r = reading {
                        let phrase = SpatialFormatter.relativeDirection(
                            bearing: r.phoneFrameBearing, heading: 0
                        )
                        announce("\(member?.displayName ?? "Friend") is \(phrase).")
                    } else {
                        announce("Direction is not available right now.")
                    }
                }
                .allowsHitTesting(false)
        }
        .onAppear {
            appState.startBLEPresence()
            appState.startUWBTracking(targetMemberID: memberID)
            // First reading should speak immediately rather than wait
            // out the throttle window.
            VoiceGuidance.shared.resetCompassThrottle()
        }
        .onDisappear { appState.stopUWBTracking() }
        .task(id: memberID) { await runHapticLoop() }
    }

    // MARK: - VoiceOver helpers

    private func compassAccessibilityLabel(reading: ArrowReading?,
                                           member: User?) -> String {
        let name = member?.displayName ?? "Friend"
        guard let reading else {
            return "Finding \(name). Locating, no signal yet."
        }
        var parts: [String] = ["Finding \(name)"]
        if let m = reading.metres {
            parts.append(SpatialFormatter.distance(meters: m))
        } else {
            parts.append(reading.distanceBand)
        }
        // phoneFrameBearing is relative to the phone (0° = top of
        // screen = where the user is "pointing"). Treat the user as
        // facing north (heading = 0) so the cardinal helper produces
        // body-relative phrasing like "ahead and to your right".
        let phrase = SpatialFormatter.relativeDirection(
            bearing: reading.phoneFrameBearing, heading: 0
        )
        parts.append(phrase)
        return parts.joined(separator: ", ")
    }

    private func compassAccessibilityValue(reading: ArrowReading?) -> String {
        guard let reading else { return "" }
        let err = abs(reading.phoneFrameBearing.truncatingRemainder(dividingBy: 360))
        let absErr = min(err, 360 - err)
        if absErr < 5 { return "Aligned" }
        if absErr < 20 { return "Almost aligned" }
        return ""
    }

    private func announce(_ message: String) {
        VoiceGuidance.shared.announce(message, priority: .high)
    }

    /// Drives the two compass haptics on a 200 ms cadence:
    ///   • Proximity pulse — variable intensity/interval scaled by
    ///     distance. `HapticEngine` self-throttles so calling every
    ///     tick is cheap; only fires as often as the cadence allows.
    ///   • Alignment tick — fires once when the user rotates the
    ///     phone into a tighter bearing zone (20°, 10°, 5°). Resets
    ///     when they drift back out so re-acquiring still buzzes.
    private func runHapticLoop() async {
        let zones: [Double] = [20, 10, 5]
        // Distance thresholds spoken to VoiceOver, in metres. Fired
        // once per crossing (going closer). Step back beyond + 20%
        // before they re-arm so we don't chatter at the boundary.
        let distanceThresholds: [Double] = [100, 30, 10, 3]
        while !Task.isCancelled {
            if let reading = arrowReading() {
                if let m = reading.metres {
                    HapticEngine.shared.proximityPulse(distanceMeters: m)
                    for t in distanceThresholds
                    where lastAnnouncedDistance > t * 1.2 && m <= t {
                        announce("Within \(SpatialFormatter.distance(meters: t))")
                        break
                    }
                    lastAnnouncedDistance = m

                    // Periodic spoken proximity update — AirTag-style.
                    // `VoiceGuidance` self-throttles to its compass
                    // interval (5s), and is a no-op when VoiceOver is
                    // off or the user has disabled spoken guidance.
                    let phrase = SpatialFormatter.relativeDirection(
                        bearing: reading.phoneFrameBearing, heading: 0
                    )
                    let name = currentMember?.displayName ?? "Friend"
                    VoiceGuidance.shared.compassUpdate(
                        "\(name), \(SpatialFormatter.distance(meters: m)), \(phrase)."
                    )
                }
                let err = min(abs(reading.phoneFrameBearing.truncatingRemainder(dividingBy: 360)),
                              360 - abs(reading.phoneFrameBearing.truncatingRemainder(dividingBy: 360)))
                for zone in zones where lastBearingError > zone && err <= zone {
                    HapticEngine.shared.compassAligned(bearingErrorDegrees: err)
                    break
                }
                // Speak "Aligned" once when we settle inside 5°,
                // re-arm once we drift back past 15°.
                if err < 5, !announcedAligned {
                    announce("Aligned")
                    announcedAligned = true
                } else if err > 15 {
                    announcedAligned = false
                }
                lastBearingError = err
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func backdrop(color: Color) -> some View {
        ZStack {
            // Base — pure white in light mode, near-black in dark.
            // The neon glow on top still pops in light mode because
            // the orb itself is fully lit; we just lose the "reactor
            // vignette" feel, which is fine.
            if colorScheme == .dark {
                Color(red: 0.02, green: 0.02, blue: 0.04)
            } else {
                Color.white
            }
            RadialGradient(
                colors: [
                    color.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    color.opacity(colorScheme == .dark ? 0.05 : 0.03),
                    .clear
                ],
                center: .center,
                startRadius: 50,
                endRadius: 500
            )
            // Top-down vignette: cyan in dark mode reinforces the
            // "reactor" feel; in light mode we use a soft accent so
            // we don't muddy the white.
            LinearGradient(
                colors: [
                    Self.orbAccent.opacity(colorScheme == .dark ? 0.08 : 0.04),
                    .clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    @ViewBuilder
    private func header(member: User?, color: Color) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 76, height: 76)
                    .blur(radius: 12)
                AvatarView(
                    data: member?.avatarData,
                    name: member?.displayName ?? "?",
                    size: 56,
                    tint: color
                )
                .overlay(
                    Circle()
                        .strokeBorder(color.opacity(0.6), lineWidth: 1)
                )
            }
            Text(member?.displayName ?? "Member")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .shadow(color: color.opacity(colorScheme == .dark ? 0.4 : 0.0),
                        radius: 8)

            Picker("Seeker mode", selection: $seekerMode) {
                ForEach(SeekerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    // MARK: - Indoor diagnostic strip

    /// Live read-out of the BLE pipeline for the targeted member. Only
    /// shown when the user explicitly picks `.indoor` — it's a
    /// debugging aid, not part of the seeker UX. The four numbers map
    /// directly to the four pipeline stages that must succeed for RSSI
    /// samples to reach the compass:
    ///   seen   — distinct peripherals discovered via scan
    ///   conn   — GATT connections currently open
    ///   map    — peripherals whose presence packet decoded (memberID
    ///            mapped). Without this, RSSI samples are dropped.
    ///   rssi   — samples received for *this* member, with age of the
    ///            last sample.
    @ViewBuilder
    private func indoorDiagnosticStrip(memberID: UUID) -> some View {
        let diag = appState.bleDiagnostics
        let rssiCount = diag.rssiSampleCountByMember[memberID] ?? 0
        let lastRSSI = diag.lastRSSITimestampByMember[memberID]
        let ageString: String = {
            guard let lastRSSI else { return "—" }
            let age = Date().timeIntervalSince(lastRSSI)
            if age < 1 { return "now" }
            if age < 60 { return "\(Int(age))s" }
            return "\(Int(age / 60))m"
        }()
        let posCount = appState.compassEngine.positionSampleCount
        let spread = appState.compassEngine.positionSpreadMetres
        let channelLabel: String = {
            switch appState.seekingDiagnostics.activeChannel {
            case .uwb: return "uwb"
            case .wifiAwareRanging: return "wa"
            case .bleRanging: return "ble"
            case .none: return "—"
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                diagnosticChip(label: "seen", value: "\(diag.discoveredPeripheralCount)")
                diagnosticChip(label: "conn", value: "\(diag.connectedPeripheralCount)")
                diagnosticChip(label: "svc", value: "\(diag.servicesDiscoveredCount)")
                diagnosticChip(label: "map", value: "\(diag.mappedMemberCount)")
                diagnosticChip(label: "rssi", value: "\(rssiCount)·\(ageString)")
            }
            HStack(spacing: 8) {
                diagnosticChip(label: "ch", value: channelLabel)
                diagnosticChip(label: "pos", value: "\(posCount)")
                diagnosticChip(label: "spread", value: String(format: "%.1fm", spread))
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func diagnosticChip(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Compass dial

    @ViewBuilder
    private func compassDial(reading: ArrowReading,
                             memberColor: Color) -> some View {
        ZStack {
            // 1. Direction ring — one continuous circle. A dim base
            //    runs all the way around in the member's color, and a
            //    bright arc lights up the portion pointing at the
            //    friend. The arc is rendered via an AngularGradient
            //    rotated so the gradient's brightest point sits at
            //    the bearing.
            DirectionRing(
                bearing: reading.phoneFrameBearing,
                color: memberColor,
                proximity: proximity(for: reading.distanceBand),
                reduceMotion: reduceMotion
            )
            // 2. Standalone diamond gem — no surrounding orb / no
            //    concentric circles. Just the gemstone glyph, glowing.
            DiamondGem(
                color: memberColor,
                confidence: reading.confidence,
                proximity: proximity(for: reading.distanceBand),
                reduceMotion: reduceMotion
            )
        }
        .animation(.smooth(duration: 0.4), value: reading.phoneFrameBearing)
    }

    /// Maps the textual `distanceBand` ("Close" / "Nearby" / etc.) onto
    /// a 0–1 proximity value the dot ring + orb pulse can scale to.
    /// Centralizing here keeps the visual response monotonic with the
    /// existing band labels.
    private func proximity(for band: String) -> Double {
        switch band {
        case "Right here":   return 1.00
        case "Close":        return 0.85
        case "Nearby":       return 0.55
        case "Further off":  return 0.30
        case "Far away":     return 0.15
        default:             return 0.40
        }
    }

    // MARK: - Distance block

    @ViewBuilder
    private func distanceBlock(reading: ArrowReading,
                               color: Color,
                               member: User?) -> some View {
        VStack(spacing: 10) {
            Text(reading.distanceBand)
                .font(.system(size: 36, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
                .shadow(color: color.opacity(colorScheme == .dark ? 0.6 : 0.15),
                        radius: 18)

            modeBadge(reading: reading, color: color)

            if let member, !reading.isFresh, reading.mode == .gps {
                Text("Last seen \(member.lastSeen.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if reading.mode == .bluetooth, reading.confidence < 0.4 {
                Text("Walk a few steps to lock on")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modeBadge(reading: ArrowReading, color: Color) -> some View {
        let (icon, label): (String, String) = {
            switch reading.mode {
            case .uwb:       return ("dot.radiowaves.up.forward", "UWB")
            case .gps:       return ("location.fill", "GPS")
            case .bluetooth: return ("antenna.radiowaves.left.and.right", "Bluetooth")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption.weight(.medium))
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
        )
        .foregroundStyle(.primary)
        .shadow(color: color.opacity(colorScheme == .dark ? 0.3 : 0.0), radius: 6)
    }

    // MARK: - Waiting state

    @ViewBuilder
    private func waitingState(member: User?) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .strokeBorder(Self.orbAccent.opacity(0.4), lineWidth: 1)
                    .frame(width: 200, height: 200)
                Image(systemName: "location.slash")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
            Text("Locking on")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
            Text("Need a fix from both of you. Make sure \(member?.displayName ?? "this member") has GroupIn open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Done button

    @ViewBuilder
    private func doneButton(color: Color) -> some View {
        Button { dismiss() } label: {
            Text("Done")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(color, lineWidth: 1.5)
                )
                .foregroundStyle(color)
        }
    }

    // MARK: - Math (unchanged from prior version)

    private enum CompassMode {
        case uwb         // NearbyInteraction — centimeter-accurate bearing + distance
        case gps         // both phones have a fresh GPS fix; bearing from haversine
        case bluetooth   // RSSI gradient over our walking path; offline-capable
    }

    private enum SeekerMode: String, CaseIterable, Identifiable {
        case auto
        case gps
        case indoor

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .gps: return "GPS"
            case .indoor: return "Indoor"
            }
        }
    }

    private struct ArrowReading {
        let phoneFrameBearing: Double  // degrees clockwise; 0 = up on screen
        let distanceBand: String
        /// Best-effort numeric distance in metres. Available for UWB
        /// and GPS modes; nil when only gradient-based mode is up.
        /// Used to drive haptic proximity pulses.
        let metres: Double?
        let isFresh: Bool
        let mode: CompassMode
        let confidence: Double         // 0–1; full opacity for GPS, R² for gradient
    }

    private struct GPSQuality {
        let hasCoordinate: Bool
        let isFresh: Bool
        let source: PositionSource
        let accuracy: Double

        var isReliableForCompass: Bool {
            hasCoordinate
                && isFresh
                && source == .gps
                && accuracy <= CompassView.maxReliableGPSAccuracy
        }

        var likelyIndoorOrUnreliable: Bool {
            source != .gps || accuracy >= CompassView.likelyIndoorGPSAccuracy
        }
    }

    private static let gpsFreshnessWindow: TimeInterval = 60
    private static let maxReliableGPSAccuracy: Double = 35
    private static let likelyIndoorGPSAccuracy: Double = 65

    private var currentMember: User? {
        appState.currentGroup?.members.first { $0.id == memberID }
    }

    private func gpsQuality(for user: User?, now: Date) -> GPSQuality {
        let source = user?.positionSource ?? .gps
        let accuracy = user?.accuracy ?? .infinity
        let lastSeen = user?.lastSeen ?? .distantPast
        return GPSQuality(
            hasCoordinate: user?.coordinate != nil,
            isFresh: now.timeIntervalSince(lastSeen) < Self.gpsFreshnessWindow,
            source: source,
            accuracy: accuracy
        )
    }

    private func arrowReading() -> ArrowReading? {
        let myHeading = appState.currentUser.heading ?? 0
        let now = Date()

        if let uwb = appState.uwbReadings[memberID],
           let direction = uwb.direction,
           now.timeIntervalSince(uwb.timestamp) < 5 {
            let bearingRad = atan2(Double(direction.x), Double(-direction.z))
            let bearingDeg = bearingRad * 180 / .pi
            return ArrowReading(
                phoneFrameBearing: bearingDeg,
                distanceBand: Self.uwbDistanceBand(metres: uwb.distance),
                metres: uwb.distance.map(Double.init),
                isFresh: true,
                mode: .uwb,
                confidence: 1.0
            )
        }

        let myQuality = gpsQuality(for: appState.currentUser, now: now)
        let theirQuality = gpsQuality(for: currentMember, now: now)

        var gpsCandidate: (worldBearing: Double, metres: Double)?
        if let myCoord = appState.currentUser.coordinate,
           let theirCoord = currentMember?.coordinate,
           myQuality.isFresh,
           theirQuality.isFresh {
            let myCL = CLLocationCoordinate2D(
                latitude: myCoord.latitude, longitude: myCoord.longitude
            )
            let theirCL = CLLocationCoordinate2D(
                latitude: theirCoord.latitude, longitude: theirCoord.longitude
            )
            gpsCandidate = (
                CompassMath.bearing(from: myCL, to: theirCL),
                CompassMath.distance(from: myCL, to: theirCL)
            )
        }

        let gradient = appState.compassEngine.gradientBearing(toMember: memberID)

        func gpsReading(_ gps: (worldBearing: Double, metres: Double)) -> ArrowReading {
            let phoneFrame = (gps.worldBearing - myHeading)
                .truncatingRemainder(dividingBy: 360)
            return ArrowReading(
                phoneFrameBearing: phoneFrame,
                distanceBand: CompassMath.distanceBand(metres: gps.metres),
                metres: gps.metres,
                isFresh: true,
                mode: .gps,
                confidence: 1.0
            )
        }

        func indoorReading(_ gradient: (bearing: Double, confidence: Double),
                           isFresh: Bool) -> ArrowReading {
            let phoneFrame = (gradient.bearing - myHeading)
                .truncatingRemainder(dividingBy: 360)
            let band = appState.compassEngine.latestRSSI(for: memberID)
                .map(CompassEngine.distanceBand(rssi:))
                ?? gpsCandidate.map { CompassMath.distanceBand(metres: $0.metres) }
                ?? "Nearby"
            return ArrowReading(
                phoneFrameBearing: phoneFrame,
                distanceBand: band,
                metres: gpsCandidate?.metres,
                isFresh: isFresh,
                mode: .bluetooth,
                confidence: gradient.confidence
            )
        }

        switch seekerMode {
        case .gps:
            if let gps = gpsCandidate {
                return gpsReading(gps)
            }
            return nil
        case .indoor:
            if let gradient {
                return indoorReading(gradient, isFresh: true)
            }
            return nil
        case .auto:
            if let gradient {
                let prefersIndoor = myQuality.likelyIndoorOrUnreliable
                    || !myQuality.isReliableForCompass
                    || !theirQuality.isReliableForCompass
                let shouldUseIndoor = prefersIndoor
                    || (gpsCandidate?.metres ?? .infinity) < 30
                if shouldUseIndoor {
                    return indoorReading(gradient, isFresh: true)
                }
            }

            if let gps = gpsCandidate {
                return gpsReading(gps)
            }

            if let gradient {
                return indoorReading(gradient, isFresh: false)
            }

            return nil
        }
    }

    private static func uwbDistanceBand(metres: Float?) -> String {
        guard let m = metres else { return "Nearby" }
        switch m {
        case ..<1.0:   return "Right here"
        case ..<5.0:   return "Close"
        case ..<15.0:  return "Nearby"
        default:       return "Further off"
        }
    }
}

// MARK: - Direction ring

/// One continuous circular ring with two clearly-distinct visual
/// layers. The eye locks onto direction instantly because there's
/// no soft fade — only a *discrete* bright arc against a dimmer
/// base ring:
///
///   • **Base ring** — always-visible 1.5pt stroke at ~35% opacity,
///     showing the full circumference so the user has the whole
///     "compass dial" as visual context.
///   • **Bright arc** — 60°-wide segment with rounded caps, much
///     thicker (5pt), much brighter (full color + bloom). Rotated
///     so the arc's *center* sits exactly at the bearing direction.
///
/// Contrast does the work: thin/medium vs thick/bright, with a
/// sharp edge between them. No gradient fade.
private struct DirectionRing: View {
    let bearing: Double         // degrees clockwise from up
    let color: Color            // per-member accent
    let proximity: Double       // 0–1; tempo + brightness scaling
    let reduceMotion: Bool

    private static let ringDiameter: CGFloat = 282
    /// Width of the bright arc in degrees. 60° = roughly a sixth of
    /// the circle — wide enough to read at a glance, narrow enough
    /// to point unambiguously.
    private static let arcSpanDegrees: Double = 60

    var body: some View {
        // Breathing on the arc's brightness only. Tempo accelerates
        // with proximity, so a friend in the same room feels alive.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30,
                                paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let rate = 1.5 + 1.5 * proximity
            let breath = reduceMotion ? 1.0 : (0.88 + 0.12 * sin(t * rate))

            ZStack {
                // Base ring — full circle, clearly visible.
                Circle()
                    .strokeBorder(
                        color.opacity(0.32),
                        lineWidth: 1.5
                    )
                    .frame(width: Self.ringDiameter, height: Self.ringDiameter)

                // Bright directional arc. `trim(from:to:)` cuts the
                // circle to a 60° segment; `.rotationEffect` then
                // positions the segment so its CENTER is at the
                // bearing direction.
                //
                // Math: SwiftUI's circle trim starts at 3 o'clock
                // (AngularGradient angle 0) and advances clockwise.
                // We want the arc's *center* at the bearing (where
                // bearing 0° = 12 o'clock).
                //   start of arc at bearing = bearing - half_arc
                //   3 o'clock + rotation = start position
                //   rotation = (bearing - half_arc) - 90  (to convert
                //              compass-frame to AngularGradient-frame)
                let halfArc = Self.arcSpanDegrees / 2
                let rotationDegrees = bearing - 90 - halfArc

                Circle()
                    .trim(from: 0, to: Self.arcSpanDegrees / 360)
                    .stroke(
                        color.opacity(breath),
                        style: StrokeStyle(
                            lineWidth: 5,
                            lineCap: .round
                        )
                    )
                    .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                    .rotationEffect(.degrees(rotationDegrees))
                    .shadow(color: color.opacity(0.9), radius: 14)
                    .shadow(color: color.opacity(0.5), radius: 32)
            }
        }
        .animation(.smooth(duration: 0.45), value: bearing)
        .animation(.smooth(duration: 0.6), value: proximity)
    }
}

// MARK: - Standalone diamond gem

/// The geometric gemstone glyph — standalone, no surrounding orb /
/// no concentric rings. Sits at the center of the screen, glows in
/// the member's color, breathes subtly with proximity.
private struct DiamondGem: View {
    let color: Color
    let confidence: Double      // 0–1; gem opacity scales with lock confidence
    let proximity: Double       // 0–1; pulse tempo + brightness
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30,
                                paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let rate = 1.8 + 2.0 * proximity
            let breath = reduceMotion ? 1.0 : (1.0 + 0.04 * sin(t * rate))
            let glow = reduceMotion ? 1.0 : (0.85 + 0.15 * sin(t * rate))

            DiamondGemShape()
                .stroke(
                    LinearGradient(
                        // Subtle top-to-bottom brightness gradient
                        // inside the stroke itself — makes the gem
                        // feel like it's catching ambient light
                        // rather than being a flat outline.
                        colors: [
                            color,
                            color.opacity(0.85),
                            color
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 92, height: 124)
                .shadow(color: color.opacity(0.9 * glow), radius: 8)
                .shadow(color: color.opacity(0.55 * glow), radius: 22)
                .shadow(color: color.opacity(0.25 * glow), radius: 50)
                .opacity(0.6 + 0.4 * confidence)
                .scaleEffect(breath)
        }
    }
}

// MARK: - Diamond gem shape

/// Classic "playing-card-suit" rhombus — sharp point at the top,
/// widest at the horizontal midpoint, sharp point at the bottom —
/// with an inscribed inner rhombus for crystal-facet depth. Reads
/// instantly as a diamond, no flat-top "table" that can look
/// truncated. The inner facet lines converge at two points on the
/// girdle (halfway in from each outer corner) to suggest the
/// brilliant-cut "kite" facets without the clutter of explicit
/// pavilion lines.
///
/// Total: 4 outer edges + 1 girdle + 4 inner facets = 9 line
/// segments. Symmetric across both axes. Looks like a refined
/// gemstone icon, not a technical diagram.
private struct DiamondGemShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let cx = rect.midX
        let cy = rect.midY
        let topY = rect.minY
        let bottomY = rect.maxY
        let leftX = rect.minX
        let rightX = rect.maxX

        // ───── 1. Outer rhombus ─────
        // Sharp points at top + bottom, widest at the horizontal
        // midline (girdle). Four straight edges, no flat table.
        let topPoint = CGPoint(x: cx, y: topY)
        let rightPoint = CGPoint(x: rightX, y: cy)   // girdle right
        let bottomPoint = CGPoint(x: cx, y: bottomY) // culet
        let leftPoint = CGPoint(x: leftX, y: cy)     // girdle left

        path.move(to: topPoint)
        path.addLine(to: rightPoint)
        path.addLine(to: bottomPoint)
        path.addLine(to: leftPoint)
        path.closeSubpath()

        // ───── 2. Girdle line ─────
        // Horizontal across the widest part. Structural — defines
        // crown vs pavilion boundary.
        path.move(to: leftPoint)
        path.addLine(to: rightPoint)

        // ───── 3. Inner facet anchors ─────
        // Two points on the girdle, halfway in from each outer
        // corner. The four inner facet lines all terminate at these
        // two points, creating an inscribed slim diamond inside
        // the wider outer one.
        let innerOffset = w * 0.26
        let innerGirdleLeft = CGPoint(x: cx - innerOffset, y: cy)
        let innerGirdleRight = CGPoint(x: cx + innerOffset, y: cy)

        // ───── 4. Crown facets (inverted V from top) ─────
        path.move(to: topPoint)
        path.addLine(to: innerGirdleLeft)
        path.move(to: topPoint)
        path.addLine(to: innerGirdleRight)

        // ───── 5. Pavilion facets (V from bottom) ─────
        // Mirrors the crown — same convergence points, opposite
        // apex. Together with the crown facets, draws a thin
        // diamond inscribed inside the wider outer rhombus.
        path.move(to: bottomPoint)
        path.addLine(to: innerGirdleLeft)
        path.move(to: bottomPoint)
        path.addLine(to: innerGirdleRight)

        return path
    }
}

// MARK: - Math utilities (unchanged)

enum CompassMath {
    /// Initial bearing in degrees clockwise from true north
    /// (great-circle bearing).
    static func bearing(from: CLLocationCoordinate2D,
                        to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Haversine great-circle distance in metres.
    static func distance(from: CLLocationCoordinate2D,
                         to: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    /// Distance bands only — TECH.md is explicit: no meter claims.
    static func distanceBand(metres: Double) -> String {
        switch metres {
        case ..<50:    return "Close"
        case ..<200:   return "Nearby"
        case ..<1000:  return "Further off"
        default:       return "Far away"
        }
    }
}

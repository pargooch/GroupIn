//
//  CompassView.swift
//  GroupIn
//
//  Full-screen "Finding X" experience. Big rotating arrow that points
//  from your current location toward the chosen member, smoothed by your
//  phone's heading so the arrow stays alive between location updates.
//
//  v1 uses position-to-position bearing (great accuracy when both phones
//  have a fresh GPS fix). RSSI-gradient fallback for offline / stale-GPS
//  cases is the next iteration.
//

import SwiftUI
import CoreLocation

struct CompassView: View {
    let memberID: UUID
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let member = currentMember
        let memberColor = Color.memberColor(for: memberID)

        ZStack {
            backdrop(color: memberColor)

            VStack(spacing: 28) {
                header(member: member, color: memberColor)
                    .padding(.top, 32)

                Spacer(minLength: 12)

                if let arrow = arrowReading() {
                    arrowDisplay(reading: arrow, color: memberColor, member: member)
                } else {
                    waitingState(member: member)
                }

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Kicks off NI session, publishes our token, attempts to
            // open a peer session if the target's token is known.
            // Bidirectional UWB only activates if the peer ALSO opens
            // their compass against us — graceful degradation otherwise.
            appState.startUWBTracking(targetMemberID: memberID)
        }
        .onDisappear {
            appState.stopUWBTracking()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func backdrop(color: Color) -> some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [color.opacity(0.35), color.opacity(0.0)],
                center: .top,
                startRadius: 60,
                endRadius: 600
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func header(member: User?, color: Color) -> some View {
        VStack(spacing: 10) {
            AvatarView(
                data: member?.avatarData,
                name: member?.displayName ?? "?",
                size: 72,
                tint: color
            )
            Text("Finding \(member?.displayName ?? "member")")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func arrowDisplay(reading: ArrowReading,
                              color: Color,
                              member: User?) -> some View {
        // In gradient mode the arrow opacity reflects confidence so the
        // user gets a visual cue when we're still locking on. GPS mode
        // is always full opacity.
        let arrowOpacity: Double = reading.mode == .gps
            ? 1.0
            : (0.35 + 0.65 * reading.confidence)

        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 1)
                    .frame(width: 280, height: 280)
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 1)
                    .frame(width: 200, height: 200)

                Image(systemName: "location.north.fill")
                    .font(.system(size: 180, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color, color.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: color.opacity(0.6), radius: 24, x: 0, y: 0)
                    .rotationEffect(.degrees(reading.phoneFrameBearing))
                    .animation(.smooth(duration: 0.4), value: reading.phoneFrameBearing)
                    .opacity(arrowOpacity)
            }

            VStack(spacing: 8) {
                Text(reading.distanceBand)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)

                modeBadge(reading: reading, color: color)

                if let member, !reading.isFresh, reading.mode == .gps {
                    Text("Last seen \(member.lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if reading.mode == .bluetooth, reading.confidence < 0.4 {
                    Text("Walk a few steps to lock on")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    @ViewBuilder
    private func modeBadge(reading: ArrowReading, color: Color) -> some View {
        let (icon, label): (String, String) = {
            switch reading.mode {
            case .uwb:       return ("dot.radiowaves.up.forward", "via UWB")
            case .gps:       return ("location.fill", "via GPS")
            case .bluetooth: return ("antenna.radiowaves.left.and.right", "via Bluetooth")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func waitingState(member: User?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "location.slash")
                .font(.system(size: 80))
                .foregroundStyle(.white.opacity(0.5))
            Text("Need a location fix from both of you")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Make sure you and \(member?.displayName ?? "this member") both have GPS active. The arrow appears when locations are flowing.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Math

    private enum CompassMode {
        case uwb         // NearbyInteraction — centimeter-accurate bearing + distance
        case gps         // both phones have a fresh GPS fix; bearing from haversine
        case bluetooth   // RSSI gradient over our walking path; offline-capable
    }

    private struct ArrowReading {
        let phoneFrameBearing: Double  // degrees clockwise; 0 = up on screen
        let distanceBand: String
        let isFresh: Bool
        let mode: CompassMode
        let confidence: Double         // 0–1; full opacity for GPS, R² for gradient
    }

    private var currentMember: User? {
        appState.currentGroup?.members.first { $0.id == memberID }
    }

    private func arrowReading() -> ArrowReading? {
        let myHeading = appState.currentUser.heading ?? 0
        let now = Date()

        // Mode 0: UWB precision finding — centimeter accuracy and a
        // direction vector that's already in device-frame, so we don't
        // even need to subtract the phone's heading. Highest priority.
        if let uwb = appState.uwbReadings[memberID],
           let direction = uwb.direction,
           now.timeIntervalSince(uwb.timestamp) < 5 {
            let bearingRad = atan2(Double(direction.x), Double(-direction.z))
            let bearingDeg = bearingRad * 180 / .pi
            return ArrowReading(
                phoneFrameBearing: bearingDeg,
                distanceBand: Self.uwbDistanceBand(metres: uwb.distance),
                isFresh: true,
                mode: .uwb,
                confidence: 1.0
            )
        }

        // Pre-compute a candidate GPS reading if both sides are fresh.
        var gpsCandidate: (worldBearing: Double, metres: Double)?
        if let myCoord = appState.currentUser.coordinate,
           let theirCoord = currentMember?.coordinate,
           let lastSeen = currentMember?.lastSeen,
           now.timeIntervalSince(lastSeen) < 60 {
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

        // At close range (<30m), GPS noise (~5m) translates to large
        // bearing error. If we have a confident RSSI gradient, prefer
        // that — proximity-based signal beats GPS at short range.
        if let gps = gpsCandidate, gps.metres < 30,
           let gradient = appState.compassEngine.gradientBearing(toMember: memberID),
           gradient.confidence > 0.3 {
            let phoneFrame = (gradient.bearing - myHeading)
                .truncatingRemainder(dividingBy: 360)
            let band = appState.compassEngine.latestRSSI(for: memberID)
                .map(CompassEngine.distanceBand(rssi:))
                ?? CompassMath.distanceBand(metres: gps.metres)
            return ArrowReading(
                phoneFrameBearing: phoneFrame,
                distanceBand: band,
                isFresh: true,
                mode: .bluetooth,
                confidence: gradient.confidence
            )
        }

        // Mode 1: position-based GPS bearing. Reliable from ~30m and up.
        if let gps = gpsCandidate {
            let phoneFrame = (gps.worldBearing - myHeading)
                .truncatingRemainder(dividingBy: 360)
            return ArrowReading(
                phoneFrameBearing: phoneFrame,
                distanceBand: CompassMath.distanceBand(metres: gps.metres),
                isFresh: true,
                mode: .gps,
                confidence: 1.0
            )
        }

        // Mode 2: gradient-only fallback when GPS isn't available at all.
        if let gradient = appState.compassEngine.gradientBearing(toMember: memberID) {
            let phoneFrame = (gradient.bearing - myHeading)
                .truncatingRemainder(dividingBy: 360)
            let band = appState.compassEngine.latestRSSI(for: memberID)
                .map(CompassEngine.distanceBand(rssi:))
                ?? "Nearby"
            return ArrowReading(
                phoneFrameBearing: phoneFrame,
                distanceBand: band,
                isFresh: false,
                mode: .bluetooth,
                confidence: gradient.confidence
            )
        }

        return nil
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

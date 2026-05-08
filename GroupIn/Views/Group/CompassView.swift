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
            }

            VStack(spacing: 6) {
                Text(reading.distanceBand)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                if let member, !reading.isFresh {
                    Text("Last seen \(member.lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
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

    private struct ArrowReading {
        let phoneFrameBearing: Double  // degrees clockwise; 0 = up on screen
        let distanceBand: String
        let isFresh: Bool
    }

    private var currentMember: User? {
        appState.currentGroup?.members.first { $0.id == memberID }
    }

    private func arrowReading() -> ArrowReading? {
        guard
            let myCoord = appState.currentUser.coordinate,
            let theirCoord = currentMember?.coordinate
        else { return nil }

        let myCL = CLLocationCoordinate2D(
            latitude: myCoord.latitude, longitude: myCoord.longitude
        )
        let theirCL = CLLocationCoordinate2D(
            latitude: theirCoord.latitude, longitude: theirCoord.longitude
        )

        let worldBearing = CompassMath.bearing(from: myCL, to: theirCL)
        let myHeading = appState.currentUser.heading ?? 0
        // Convert world-frame bearing into phone-frame: subtract the
        // direction the phone is facing. 0° in phone-frame = "in front."
        let phoneFrame = (worldBearing - myHeading).truncatingRemainder(dividingBy: 360)

        let metres = CompassMath.distance(from: myCL, to: theirCL)

        // Member is "fresh" if their lastSeen is within the live window.
        let fresh = currentMember.map {
            Date().timeIntervalSince($0.lastSeen) < 60
        } ?? false

        return ArrowReading(
            phoneFrameBearing: phoneFrame,
            distanceBand: CompassMath.distanceBand(metres: metres),
            isFresh: fresh
        )
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

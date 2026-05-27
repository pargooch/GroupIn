//
//  MemberListSheet.swift
//  GroupIn
//
//  Draggable bottom sheet listing group members by distance from the
//  local user. Rows show avatar / name / live distance / direction
//  arrow (true bearing − user heading, so ↑ = ahead of you) /
//  last-seen. Tapping a row sets `focusedMemberID`, which the map
//  reacts to (camera + glowing route).
//
//  Presented from `GroupDashboardView` via `.sheet` with
//  `.presentationDetents([.height(80), .fraction(0.4), .large])`,
//  so the user pulls it up when they want the list and pushes it
//  down to see the cinematic map.
//

import SwiftUI
import CoreLocation

struct MemberListSheet: View {
    let members: [User]
    let currentMemberID: UUID
    let now: Date
    @Binding var focusedMemberID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(rows, id: \.member.id) { row in
                        Button {
                            focusedMemberID = (focusedMemberID == row.member.id)
                                ? nil
                                : row.member.id
                        } label: {
                            MemberRow(row: row,
                                      focused: focusedMemberID == row.member.id,
                                      color: color(for: row.member.id))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            color(for: row.member.id)
                                .opacity(focusedMemberID == row.member.id ? 0.45 : 0.28)
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.dashed")
                .font(.title)
                .foregroundStyle(.white.opacity(0.6))
            Text("No live members yet")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
            Text("As soon as someone shares their location they'll show up here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Row data

    private struct Row {
        let member: User
        let distance: Double?
        let bearingDegrees: Double?
        let lastSeen: Date
    }

    private var localUser: User? {
        members.first { $0.id == currentMemberID }
    }

    private var rows: [Row] {
        let me = localUser
        return members
            .filter { $0.id != currentMemberID }
            .map { peer -> Row in
                let d = distance(from: me, to: peer)
                let b = bearing(from: me, to: peer)
                return Row(member: peer,
                           distance: d,
                           bearingDegrees: b,
                           lastSeen: peer.lastSeen)
            }
            .sorted { a, b in
                switch (a.distance, b.distance) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:            return a.member.displayName < b.member.displayName
                }
            }
    }

    private func distance(from me: User?, to peer: User) -> Double? {
        guard let a = me?.coordinate, let b = peer.coordinate else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func bearing(from me: User?, to peer: User) -> Double? {
        guard let me, let a = me.coordinate, let b = peer.coordinate else { return nil }
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    /// Collision-free color for a member within this sheet's member set.
    private func color(for memberID: UUID) -> Color {
        Color.memberColor(for: memberID, among: members.map(\.id))
    }

    private struct MemberRow: View {
        let row: Row
        let focused: Bool
        let color: Color

        @Environment(AppState.self) private var appState

        var body: some View {
            HStack(spacing: 12) {
                AvatarView(data: row.member.avatarData,
                           name: row.member.displayName,
                           size: 40,
                           tint: color)
                    .overlay(
                        Circle().strokeBorder(
                            color,
                            lineWidth: focused ? 2 : 1
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.member.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        Text(distanceText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.3))
                        Text(row.lastSeen, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                directionArrow
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(focused ? "Route drawn on map" : "")
            .accessibilityHint("Double tap to toggle the route on the map.")
        }

        /// Comprehensive spoken summary read by VoiceOver, in place of
        /// the row's individual labels: "Alex, 120 meters, northeast,
        /// last seen 2 minutes ago".
        private var spokenLabel: String {
            var parts: [String] = [row.member.displayName]
            if let d = row.distance {
                parts.append(SpatialFormatter.distance(meters: d))
            }
            if let bearing = row.bearingDegrees {
                parts.append(SpatialFormatter.direction(
                    bearing: bearing,
                    userHeading: appState.currentUser.heading
                ))
            }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            parts.append("last seen \(relative.localizedString(for: row.lastSeen, relativeTo: .now))")
            return parts.joined(separator: ", ")
        }

        private var distanceText: String {
            guard let d = row.distance else { return "—" }
            if d >= 1000 { return String(format: "%.1f km", d / 1000) }
            return "\(Int(d.rounded())) m"
        }

        @ViewBuilder
        private var directionArrow: some View {
            if let bearing = row.bearingDegrees {
                // Use the local user's compass heading so the arrow
                // points relative to where the user is currently
                // facing. Falls back to north-up when heading is
                // unavailable.
                let heading = appState.currentUser.heading ?? 0
                let relative = bearing - heading
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(relative))
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 28, height: 28)
            }
        }
    }
}

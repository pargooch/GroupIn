//
//  MemberColors.swift
//  GroupIn
//
//  Deterministic color-per-member: we hash the membership UUID into a
//  fixed palette. Same member always gets the same color across sessions
//  and across devices, so visual identity is stable.
//

import SwiftUI

extension Color {
    static let memberPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink,
        .red, .teal, .indigo, .yellow, .mint, .cyan, .brown
    ]

    /// Legacy hash → color. May collide for two different members
    /// (~1-in-palette odds). Used only when the group's member set
    /// isn't available (e.g. an ex-member in old chat history). Prefer
    /// `memberColor(for:among:)` whenever the member list is known.
    static func memberColor(for memberID: UUID) -> Color {
        memberPalette[preferredIndex(for: memberID)]
    }

    private static func preferredIndex(for memberID: UUID) -> Int {
        let bytes = withUnsafeBytes(of: memberID.uuid) { Array($0) }
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return Int(sum) % memberPalette.count
    }

    /// Collision-free color assignment across a group's members: each
    /// member keeps their hash-preferred color when it's free, otherwise
    /// probes to the next open palette slot, so no two members share a
    /// color until the group exceeds the palette size. Deterministic
    /// across devices — members are processed in a stable (sorted) order,
    /// so every device computes the same assignment.
    static func memberColors(among memberIDs: [UUID]) -> [UUID: Color] {
        let ordered = memberIDs.sorted { $0.uuidString < $1.uuidString }
        var used = Set<Int>()
        var map: [UUID: Color] = [:]
        for id in ordered {
            var idx = preferredIndex(for: id)
            var probes = 0
            while used.contains(idx) && probes < memberPalette.count {
                idx = (idx + 1) % memberPalette.count
                probes += 1
            }
            used.insert(idx)
            map[id] = memberPalette[idx]
        }
        return map
    }

    /// Collision-free color for one member within a group.
    static func memberColor(for memberID: UUID, among memberIDs: [UUID]) -> Color {
        memberColors(among: memberIDs)[memberID] ?? memberColor(for: memberID)
    }
}

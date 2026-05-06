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

    static func memberColor(for memberID: UUID) -> Color {
        let bytes = withUnsafeBytes(of: memberID.uuid) { Array($0) }
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return memberPalette[Int(sum) % memberPalette.count]
    }
}

//
//  PeerLinkIndicator.swift
//  GroupIn
//
//  Tiny chip showing whether the peer-to-peer payload transport
//  (Multipeer Connectivity) is actually linked to anyone right now.
//
//  Polled (not observed) by design: a previous attempt to surface the
//  same data via @Observable cascaded through SwiftUI's invalidation
//  graph and tripped the CPU watchdog. Here we sample
//  `currentDiagnosticsSnapshot` on a TimelineView clock so the read is
//  cheap, deterministic, and contained to this view.
//

import SwiftUI

struct PeerLinkIndicator: View {
    /// Captured once at init so the view does NOT observe AppState. The
    /// transport itself is not @Observable, so reading a snapshot from
    /// it inside `body` is free of side-effects on the observation
    /// graph. Optional because per-group transports come and go with
    /// scene phase / membership; nil renders as "Link off."
    let transport: PayloadTransport?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let diag = transport?.currentDiagnosticsSnapshot
                ?? TransportDiagnostics.inactive
            chip(for: diag)
        }
    }

    @ViewBuilder
    private func chip(for diag: TransportDiagnostics) -> some View {
        let color: Color = {
            if !diag.isActive { return .secondary }
            if diag.connectedPeers > 0 { return .green }
            if diag.discoveredPeerCount > 0 { return .orange }
            return .red
        }()

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label(for: diag))
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel(accessibilityLabel(for: diag))
    }

    private func label(for diag: TransportDiagnostics) -> String {
        guard diag.isActive else { return "Link off" }
        let n = diag.connectedPeers
        if n > 0 { return "Linked \(n)" }
        let d = diag.discoveredPeerCount
        if d > 0 { return "Seen \(d)" }
        return "Searching"
    }

    private func accessibilityLabel(for diag: TransportDiagnostics) -> String {
        guard diag.isActive else { return "Peer link inactive" }
        return "\(diag.connectedPeers) connected, \(diag.discoveredPeerCount) discovered, \(diag.invitedPeerCount) invited"
    }
}

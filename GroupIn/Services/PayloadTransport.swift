//
//  PayloadTransport.swift
//  GroupIn
//
//  Unified surface for the "payload tier" — anything beyond presence
//  heartbeats and the join handshake (which stay on BLE). Concrete
//  transports today: MultipeerConnectivity. Wi-Fi Aware (NAN) lands in
//  Phase 4 behind the same protocol.
//
//  Architecture: BLE is the signaling layer (discovery, presence,
//  wake-on-proximity). PayloadTransport is the bandwidth layer (chat,
//  event-log gossip, member roster, avatars). The transport selected
//  per group is the *minimum* capability across members — every member
//  must support the chosen transport or the group falls back to a
//  lower tier. See `PayloadTransportRouter`.
//

import Foundation

/// Stable identifier of a peer over a payload transport. The `raw`
/// string is whatever identity the underlying transport surfaces
/// (MPC: `displayName`; Wi-Fi Aware: service identifier). Consumers
/// should treat it as opaque.
nonisolated struct TransportPeerID: Hashable, Sendable {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }
}

/// One inbound packet from a connected peer.
nonisolated struct TransportPacket: Sendable {
    let peer: TransportPeerID
    let data: Data
}

/// Lifecycle event for a transport peer.
nonisolated enum TransportPeerEvent: Sendable {
    case connected(TransportPeerID)
    case disconnected(TransportPeerID)
}

/// Transport-level diagnostics. Mirrors `BLEDiagnostics` in shape so
/// the UI can surface a single "connectivity" view that summarizes
/// both layers.
nonisolated struct TransportDiagnostics: Sendable, Equatable {
    var connectedPeers: Int
    var isActive: Bool
    var selection: TransportSelection?

    /// Observability for the discovery layer (MPC browser / Wi-Fi
    /// Aware subscriber). `discoveredPeerCount` counts every peer
    /// we've seen advertising on the same service type — the count
    /// staying at 0 while `isBrowsing == true` usually means Local
    /// Network permission was denied. `invitedPeerCount` counts how
    /// many of those we've sent session invitations to, useful for
    /// telling "discovery works but invitations stall" apart from
    /// "discovery itself never finds anyone".
    var isBrowsing: Bool = false
    var isAdvertising: Bool = false
    var discoveredPeerCount: Int = 0
    var invitedPeerCount: Int = 0

    static let inactive = TransportDiagnostics(
        connectedPeers: 0,
        isActive: false,
        selection: nil
    )
}

/// Which payload transport the router is currently driving. `none`
/// means no transport is up (group is idle, transport teardown, or
/// the negotiated selection isn't available on this device).
enum TransportSelection: String, Sendable, Equatable, Codable {
    /// Multipeer Connectivity. Available on every iOS device. Fallback
    /// when not all members support Wi-Fi Aware. Range ~30–100m
    /// depending on radio assist; 8-peer cap per session.
    case multipeer

    /// Wi-Fi Aware (NAN). iOS 26+, hardware-dependent. Preferred when
    /// every group member can run it: ~100–200m range, higher
    /// bandwidth, lower latency than MPC. Phase 4.
    case wifiAware
}

/// Common surface for any concrete transport (MPC, Wi-Fi Aware) and
/// the router that picks between them.
@MainActor
protocol PayloadTransport: AnyObject {
    /// Inbound packets from connected peers.
    var incoming: AsyncStream<TransportPacket> { get }

    /// Peer lifecycle (connect / disconnect).
    var peerEvents: AsyncStream<TransportPeerEvent> { get }

    /// Diagnostics — peer count, active flag, current selection.
    var diagnostics: AsyncStream<TransportDiagnostics> { get }

    /// Which transport this instance represents. For the router, the
    /// currently selected child; for a concrete transport, its own
    /// flavor.
    var selection: TransportSelection { get }

    /// Begin advertising and browsing under the given identity and
    /// rendezvous token. Idempotent — calling again with new args
    /// restarts the session cleanly.
    func start(displayName: String, rendezvousToken: String)

    /// Tear down all sessions and stop advertising/browsing.
    func stop()

    /// Send to a specific connected peer. Throws if the peer isn't
    /// currently reachable on this transport.
    func send(_ data: Data, to peer: TransportPeerID) throws

    /// Broadcast to every connected peer. Per-peer failures are
    /// swallowed; callers can watch diagnostics for reach.
    func broadcast(_ data: Data)

    /// Switch the active transport, if this instance is a router that
    /// can multiplex. Single-transport implementations should treat
    /// this as a no-op (the default extension does).
    func select(_ selection: TransportSelection)
}

extension PayloadTransport {
    func select(_ selection: TransportSelection) {
        // Single-transport implementations have no selection to make.
    }
}

/// Capability bits for a single device. Advertised on the BLE
/// presence channel (Phase 4) so the group can negotiate the
/// minimum-common transport.
struct TransportCapability: Sendable, Equatable, Codable {
    /// Wi-Fi Aware available on this device (iOS 26+, hardware
    /// supports it, entitlement granted, radio on).
    var wifiAware: Bool

    /// MPC available (Local Network permission granted, not airplane
    /// mode with Bluetooth + Wi-Fi both off).
    var multipeer: Bool

    static let none = TransportCapability(wifiAware: false, multipeer: false)
    static let mpcOnly = TransportCapability(wifiAware: false, multipeer: true)
    static let full = TransportCapability(wifiAware: true, multipeer: true)
}

extension TransportCapability {
    /// Pick the highest-tier transport supported by every member's
    /// capability set. Wi-Fi Aware wins if *everyone* has it;
    /// otherwise MPC; otherwise nothing.
    static func groupMinimum(across capabilities: [TransportCapability]) -> TransportSelection? {
        guard !capabilities.isEmpty else { return nil }
        if capabilities.allSatisfy({ $0.wifiAware }) { return .wifiAware }
        if capabilities.allSatisfy({ $0.multipeer }) { return .multipeer }
        return nil
    }
}

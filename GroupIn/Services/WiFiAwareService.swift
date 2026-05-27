//
//  WiFiAwareService.swift
//  GroupIn
//
//  Wi-Fi Aware (NAN) implementation of `PayloadTransport`. Preferred
//  transport when every group member can run it: ~100–200m range, much
//  higher bandwidth than MPC, lower latency. iOS 26+ exposes the
//  `WiFiAware` framework which uses Apple's pairing model and a
//  publisher/subscriber service shape to bring up data paths.
//
//  Scaffolding status: this is a structural stub conforming to the
//  same `PayloadTransport` surface as `MultipeerService`. The actual
//  Wi-Fi Aware publish/subscribe/pair/data-path setup will fill in
//  inside the marked TODO blocks. Until then, this transport reports
//  `isActive = false` after `start(...)` and the router's group-min
//  negotiation will fall back to MPC for the group.
//

import Foundation

@MainActor
final class WiFiAwareService: PayloadTransport {

    /// Service identifier presented over Wi-Fi Aware's publish/
    /// subscribe matching. Mirrors MPC's serviceType + rendezvous
    /// pattern: the suffix carries the rendezvous token so two
    /// nearby GroupIn groups don't cross-talk.
    nonisolated static let serviceNamePrefix = "groupin-wa-v1"

    // MARK: PayloadTransport

    let incoming: AsyncStream<TransportPacket>
    let peerEvents: AsyncStream<TransportPeerEvent>
    let diagnostics: AsyncStream<TransportDiagnostics>
    let selection: TransportSelection = .wifiAware

    private nonisolated let incomingContinuation: AsyncStream<TransportPacket>.Continuation
    private nonisolated let peerEventsContinuation: AsyncStream<TransportPeerEvent>.Continuation
    private nonisolated let diagnosticsContinuation: AsyncStream<TransportDiagnostics>.Continuation

    // MARK: State

    /// Whether the transport has been brought up. The real implementation
    /// will gate this on Wi-Fi Aware availability, entitlement, radio
    /// state, and successful publisher/subscriber start.
    private var isActive: Bool = false

    private var currentDiagnostics = TransportDiagnostics(
        connectedPeers: 0,
        isActive: false,
        selection: .wifiAware
    )

    var currentDiagnosticsSnapshot: TransportDiagnostics { currentDiagnostics }

    // MARK: Init

    init() {
        let (incomingStream, incomingCont) = AsyncStream.makeStream(of: TransportPacket.self)
        let (eventsStream, eventsCont) = AsyncStream.makeStream(of: TransportPeerEvent.self)
        let (diagStream, diagCont) = AsyncStream.makeStream(of: TransportDiagnostics.self)
        self.incoming = incomingStream
        self.peerEvents = eventsStream
        self.diagnostics = diagStream
        self.incomingContinuation = incomingCont
        self.peerEventsContinuation = eventsCont
        self.diagnosticsContinuation = diagCont
    }

    // MARK: Lifecycle

    func start(displayName: String, rendezvousToken: String) {
        // TODO(Phase 4 follow-up): bring up the Wi-Fi Aware publisher +
        // subscriber here. Sketch:
        //
        //   1. Build a service name = "\(serviceNamePrefix).\(rendezvousToken)".
        //   2. Publish (WAPublishableService) using the device's identity.
        //   3. Subscribe (WASubscribableService) for matches under the
        //      same name. Auto-pair via the BLE-derived shared secret —
        //      no PIN UX, since the rendezvous token + future v2 group
        //      key already authenticate the peer.
        //   4. On match, open a data path (TCP socket via Wi-Fi Aware's
        //      interface). Wrap reads as `TransportPacket`s into
        //      `incomingContinuation`.
        //   5. On disconnect, yield `.disconnected(...)` and tear the
        //      data path down.
        //
        // Until the framework path is wired, this is a no-op and the
        // transport reports inactive. Capability advertisement in
        // PeerPresence stays `wifiAware = false` for this device, so
        // the group-min selector keeps us on MPC.
        isActive = false
        currentDiagnostics = TransportDiagnostics(
            connectedPeers: 0,
            isActive: false,
            selection: .wifiAware
        )
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func stop() {
        // Mirror of start — tear down publisher/subscriber/data path
        // once `start` actually brings them up.
        isActive = false
        currentDiagnostics = TransportDiagnostics(
            connectedPeers: 0,
            isActive: false,
            selection: .wifiAware
        )
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func send(_ data: Data, to peer: TransportPeerID) throws {
        throw TransportError.transportNotActive
    }

    func broadcast(_ data: Data) {
        // No-op while the real transport is unwired.
    }

    // MARK: Capability

    /// Whether the running OS / device actually supports Wi-Fi Aware.
    /// Becomes meaningful once `start(...)` is real; for now returns
    /// false so the group-min selector consistently picks MPC.
    nonisolated static func deviceSupportsWiFiAware() -> Bool {
        // TODO: probe `WiFiAware.isSupported` (or equivalent API) once
        // we wire the framework. iOS 26.2 is already the minimum, so
        // the only remaining gate is hardware + entitlement.
        return false
    }
}

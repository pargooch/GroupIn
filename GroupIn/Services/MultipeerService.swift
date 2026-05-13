//
//  MultipeerService.swift
//  GroupIn
//
//  Multipeer Connectivity implementation of `PayloadTransport`. Used as
//  the fallback when Wi-Fi Aware isn't supported by every group member
//  — see `PayloadTransport.groupMinimum(...)` and the router. MPC uses
//  Bluetooth Classic + Wi-Fi Peer-to-Peer + infrastructure Wi-Fi
//  opportunistically; range and bandwidth both beat raw BLE GATT.
//
//  Wire layer only: discovery, session lifecycle, send/receive. Higher-
//  level concerns (group filtering, event-cursor gossip, encryption v2)
//  live above this in the router and AppState.
//

import Foundation
import MultipeerConnectivity

@MainActor
final class MultipeerService: NSObject, PayloadTransport {

    /// MPC service type. Rules: 1–15 characters, lowercase letters,
    /// digits, hyphens. Versioned so v2 (encryption) can run alongside
    /// v1 without cross-talk.
    nonisolated static let serviceType = "groupin-v1"

    /// Key in the advertiser's discovery-info dict carrying the
    /// rendezvous token. Browsers inspect this before inviting; an
    /// out-of-group peer is skipped silently. Total discovery-info
    /// size is capped at ~400 bytes by MPC, so keep this short.
    nonisolated static let discoveryKeyRendezvous = "rdv"

    // MARK: PayloadTransport

    let incoming: AsyncStream<TransportPacket>
    let peerEvents: AsyncStream<TransportPeerEvent>
    let diagnostics: AsyncStream<TransportDiagnostics>
    let selection: TransportSelection = .multipeer

    private nonisolated let incomingContinuation: AsyncStream<TransportPacket>.Continuation
    private nonisolated let peerEventsContinuation: AsyncStream<TransportPeerEvent>.Continuation
    private nonisolated let diagnosticsContinuation: AsyncStream<TransportDiagnostics>.Continuation

    // MARK: State

    private var localPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Active rendezvous token. Used to decide whether to invite a
    /// discovered peer (their discovery-info must match) and whether
    /// to accept an invitation (the inviter's context must match).
    /// Cleared on stop().
    private var activeRendezvousToken: String?

    /// Stable connected-peer lookup keyed by `TransportPeerID.raw`
    /// (= displayName). MCSession holds the canonical `MCPeerID`
    /// references; this map lets `send(to:)` resolve a stable string
    /// ID back to the MPC object.
    private var connectedByDisplayName: [String: MCPeerID] = [:]

    private var currentDiagnostics = TransportDiagnostics(
        connectedPeers: 0,
        isActive: false,
        selection: .multipeer
    )

    // MARK: Init

    override init() {
        let (incomingStream, incomingCont) = AsyncStream.makeStream(of: TransportPacket.self)
        let (eventsStream, eventsCont) = AsyncStream.makeStream(of: TransportPeerEvent.self)
        let (diagStream, diagCont) = AsyncStream.makeStream(of: TransportDiagnostics.self)
        self.incoming = incomingStream
        self.peerEvents = eventsStream
        self.diagnostics = diagStream
        self.incomingContinuation = incomingCont
        self.peerEventsContinuation = eventsCont
        self.diagnosticsContinuation = diagCont
        super.init()
    }

    // MARK: Lifecycle

    func start(displayName: String, rendezvousToken: String) {
        stop()

        activeRendezvousToken = rendezvousToken

        let peer = MCPeerID(displayName: displayName)
        // .required uses MPC-generated ephemeral certs and gives us
        // transport-level TLS for free — meaningful even before app-
        // level encryption (v2) lands.
        let mcSession = MCSession(
            peer: peer,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        mcSession.delegate = self

        let info = [Self.discoveryKeyRendezvous: rendezvousToken]
        let adv = MCNearbyServiceAdvertiser(
            peer: peer,
            discoveryInfo: info,
            serviceType: Self.serviceType
        )
        adv.delegate = self

        let bro = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        bro.delegate = self

        self.localPeerID = peer
        self.session = mcSession
        self.advertiser = adv
        self.browser = bro

        adv.startAdvertisingPeer()
        bro.startBrowsingForPeers()

        currentDiagnostics = TransportDiagnostics(
            connectedPeers: 0,
            isActive: true,
            selection: .multipeer
        )
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        advertiser?.delegate = nil
        browser?.delegate = nil
        session?.delegate = nil

        advertiser = nil
        browser = nil
        session = nil
        localPeerID = nil
        activeRendezvousToken = nil
        connectedByDisplayName.removeAll()

        currentDiagnostics = TransportDiagnostics(
            connectedPeers: 0,
            isActive: false,
            selection: .multipeer
        )
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    func send(_ data: Data, to peer: TransportPeerID) throws {
        guard let session, let mcPeer = connectedByDisplayName[peer.raw] else {
            throw TransportError.peerNotConnected(peer)
        }
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    func broadcast(_ data: Data) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            // Per-peer failures surface via peerEvents (.disconnected)
            // when the session marks the link down; nothing actionable
            // here.
        }
    }

    // MARK: Helpers (main actor)

    private func updateConnectedCount() {
        currentDiagnostics.connectedPeers = connectedByDisplayName.count
        diagnosticsContinuation.yield(currentDiagnostics)
    }
}

// MARK: - Errors

enum TransportError: Error {
    case peerNotConnected(TransportPeerID)
    case transportNotActive
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {

    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let displayName = peerID.displayName
        Task { @MainActor in
            switch state {
            case .connected:
                self.connectedByDisplayName[displayName] = peerID
                self.peerEventsContinuation.yield(
                    .connected(TransportPeerID(displayName))
                )
                self.updateConnectedCount()
            case .notConnected:
                if self.connectedByDisplayName.removeValue(forKey: displayName) != nil {
                    self.peerEventsContinuation.yield(
                        .disconnected(TransportPeerID(displayName))
                    )
                    self.updateConnectedCount()
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let packet = TransportPacket(
            peer: TransportPeerID(peerID.displayName),
            data: data
        )
        incomingContinuation.yield(packet)
    }

    // The remaining MCSessionDelegate methods are required but unused —
    // GroupIn doesn't move streams, file resources, or custom certs over
    // MPC. The default no-op implementations satisfy the protocol.

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        // No pinning — accept any ephemeral cert MPC presents. The
        // rendezvous-token check at the advertiser layer is what gates
        // group membership; this callback only validates transport TLS.
        certificateHandler(true)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let inviterToken = context.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            guard let token = self.activeRendezvousToken,
                  inviterToken == token,
                  let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor in
            self.currentDiagnostics.isActive = false
            self.diagnosticsContinuation.yield(self.currentDiagnostics)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerService: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peerToken = info?[Self.discoveryKeyRendezvous]
        Task { @MainActor in
            guard let token = self.activeRendezvousToken,
                  peerToken == token,
                  let session = self.session,
                  let local = self.localPeerID else {
                return
            }
            // Deterministic invite direction to avoid two peers
            // double-inviting each other and racing into half-open
            // sessions: only the peer whose displayName sorts lower
            // sends the invite. The other side accepts.
            guard local.displayName < peerID.displayName else { return }

            let context = token.data(using: .utf8)
            browser.invitePeer(
                peerID,
                to: session,
                withContext: context,
                timeout: 10
            )
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        // Loss handled through MCSession state transitions; nothing
        // to do here. Browser sees "lost" before the session reports
        // disconnect; relying on the session event keeps connected/
        // disconnected counts honest.
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        Task { @MainActor in
            self.currentDiagnostics.isActive = false
            self.diagnosticsContinuation.yield(self.currentDiagnostics)
        }
    }
}

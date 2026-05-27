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

    /// Process-level `MCPeerID` cache. MPC is documented as expecting
    /// one MCPeerID per (process, displayName) pair: the framework
    /// keys daemon-side resources to that object's identity. Creating
    /// fresh instances per `start()` strands those resources and the
    /// next session silently fails to advertise. Keyed by displayName
    /// so per-group memberIDs each get their own stable peer.
    nonisolated(unsafe) private static var peerIDCache: [String: MCPeerID] = [:]
    nonisolated private static let peerIDCacheLock = NSLock()

    nonisolated static func cachedPeerID(forDisplayName displayName: String) -> MCPeerID {
        peerIDCacheLock.lock()
        defer { peerIDCacheLock.unlock() }
        if let existing = peerIDCache[displayName] { return existing }
        let fresh = MCPeerID(displayName: displayName)
        peerIDCache[displayName] = fresh
        return fresh
    }

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

    /// Every MCPeerID display name we've seen via `foundPeer`, kept
    /// for diagnostics. Separate from `connectedByDisplayName` —
    /// "discovered" is a strict superset of "connected" and the gap
    /// is the most useful signal for diagnosing Local Network
    /// permission or invitation failures.
    private var discoveredDisplayNames: Set<String> = []

    /// Display names we've sent an MPC invitation to. The gap between
    /// invited and connected is where invitation timeouts and
    /// invitation refusals show up.
    private var invitedDisplayNames: Set<String> = []

    /// Discovered MCPeerID references keyed by displayName, so the
    /// retry loop can re-invite without waiting for `foundPeer` to
    /// fire again (which on some AWDL setups can take minutes).
    private var discoveredPeers: [String: MCPeerID] = [:]

    /// How many times we've invited a given peer this start-cycle.
    /// Capped to avoid an indefinite invite storm on a peer that
    /// keeps refusing or is genuinely unreachable.
    private var inviteAttempts: [String: Int] = [:]

    private static let maxInviteAttempts = 4
    private static let invitationTimeout: TimeInterval = 30
    private static let retryDelay: TimeInterval = 12

    private var currentDiagnostics = TransportDiagnostics(
        connectedPeers: 0,
        isActive: false,
        selection: .multipeer
    )

    var currentDiagnosticsSnapshot: TransportDiagnostics { currentDiagnostics }

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

        // Reuse the same MCPeerID instance for this displayName across
        // every start/stop cycle in this process. Apple's MPC framework
        // expects one MCPeerID per (process, displayName) — making a
        // fresh one each call leaves daemon-side state attached to the
        // *previous* MCPeerID, which is the root cause of "foreground
        // after a long background no longer handshakes; only cold
        // launch fixes it." Cold launch wipes the cache too; in-process
        // cycles must reuse to avoid that wedge.
        let peer = Self.cachedPeerID(forDisplayName: displayName)
        // .optional, not .required. We learned the hard way that
        // requiring DTLS over AWDL/Bluetooth pegs the session in
        // "connecting" past the invitation timeout on cellular-only
        // phones and on flaky Wi-Fi peer-to-peer setups — peers stay
        // stuck on "Seen" forever. The wide-area copy of every payload
        // is already E2E-encrypted in CloudKit (ChaChaPoly + HKDF from
        // the invite code), so the proximity link doesn't need its own
        // TLS to be safe. `.optional` still negotiates encryption when
        // both ends are ready; it just won't BLOCK the handshake.
        let mcSession = MCSession(
            peer: peer,
            securityIdentity: nil,
            encryptionPreference: .optional
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
            selection: .multipeer,
            isBrowsing: true,
            isAdvertising: true,
            discoveredPeerCount: 0,
            invitedPeerCount: 0
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
        discoveredDisplayNames.removeAll()
        invitedDisplayNames.removeAll()
        discoveredPeers.removeAll()
        inviteAttempts.removeAll()

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

    private func updateDiscoveryCounts() {
        currentDiagnostics.discoveredPeerCount = discoveredDisplayNames.count
        currentDiagnostics.invitedPeerCount = invitedDisplayNames.count
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
            self.currentDiagnostics.isAdvertising = false
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
        let displayName = peerID.displayName
        Task { @MainActor in
            // Count every peer that surfaces on our service type — the
            // discovery layer is shared across all groups, so this can
            // include peers we won't actually invite (different token).
            // Still useful diagnostically: zero discoveries while
            // browsing == true is a strong signal of a permission or
            // service-type problem.
            if self.discoveredDisplayNames.insert(displayName).inserted {
                self.updateDiscoveryCounts()
            }
            self.discoveredPeers[displayName] = peerID

            guard let token = self.activeRendezvousToken,
                  peerToken == token,
                  let local = self.localPeerID else {
                return
            }
            // Deterministic invite direction to avoid two peers
            // double-inviting each other and racing into half-open
            // sessions: only the peer whose displayName sorts lower
            // sends the invite. The other side accepts.
            guard local.displayName < peerID.displayName else { return }

            self.attemptInvite(peerID: peerID, token: token)
        }
    }

    /// Send an MPC invitation to `peerID` and schedule a retry. AWDL
    /// can take 10–20 s to bring up on cellular-only phones, and the
    /// invitation timeout would otherwise expire silently and leave
    /// the session stuck on "Seen" with no second attempt. We retry
    /// up to `maxInviteAttempts` times on a `retryDelay` cadence —
    /// the retry is a no-op if the peer is already connected.
    @MainActor
    private func attemptInvite(peerID: MCPeerID, token: String) {
        guard let session = self.session,
              let browser = self.browser else { return }
        let displayName = peerID.displayName
        guard self.connectedByDisplayName[displayName] == nil else { return }

        let attempt = (self.inviteAttempts[displayName] ?? 0) + 1
        guard attempt <= Self.maxInviteAttempts else { return }
        self.inviteAttempts[displayName] = attempt

        let context = token.data(using: .utf8)
        browser.invitePeer(
            peerID,
            to: session,
            withContext: context,
            timeout: Self.invitationTimeout
        )
        if self.invitedDisplayNames.insert(displayName).inserted {
            self.updateDiscoveryCounts()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.retryDelay))
            guard let self,
                  self.connectedByDisplayName[displayName] == nil,
                  let stillDiscovered = self.discoveredPeers[displayName],
                  let activeToken = self.activeRendezvousToken else { return }
            self.attemptInvite(peerID: stillDiscovered, token: activeToken)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        let displayName = peerID.displayName
        Task { @MainActor in
            // Drop from the discovery set so the indicator stops
            // showing "Seen N" for peers that have actually gone away.
            // Connection state still flows through MCSession (which
            // reports disconnect after the link goes down); this only
            // updates the "discovered but never connected" view.
            if self.discoveredDisplayNames.remove(displayName) != nil {
                self.updateDiscoveryCounts()
            }
            self.discoveredPeers.removeValue(forKey: displayName)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        Task { @MainActor in
            self.currentDiagnostics.isActive = false
            self.currentDiagnostics.isBrowsing = false
            self.diagnosticsContinuation.yield(self.currentDiagnostics)
        }
    }
}

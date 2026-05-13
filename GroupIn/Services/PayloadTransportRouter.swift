//
//  PayloadTransportRouter.swift
//  GroupIn
//
//  Selects a single payload transport for the group and presents a
//  unified `PayloadTransport` surface to AppState. The active transport
//  is dictated by group-min capability: Wi-Fi Aware if every member
//  supports it, otherwise MPC. The router knows nothing about the
//  capability negotiation itself — AppState computes the selection and
//  calls `select(_:)` here.
//
//  Phase 2 ships with MPC only; Wi-Fi Aware lands in Phase 4 as an
//  additional child plugged into the same router.
//

import Foundation

@MainActor
final class PayloadTransportRouter: PayloadTransport {

    // MARK: PayloadTransport surface

    let incoming: AsyncStream<TransportPacket>
    let peerEvents: AsyncStream<TransportPeerEvent>
    let diagnostics: AsyncStream<TransportDiagnostics>
    private(set) var selection: TransportSelection

    private let incomingContinuation: AsyncStream<TransportPacket>.Continuation
    private let peerEventsContinuation: AsyncStream<TransportPeerEvent>.Continuation
    private let diagnosticsContinuation: AsyncStream<TransportDiagnostics>.Continuation

    // MARK: Children

    private let multipeer: PayloadTransport
    private let wifiAware: PayloadTransport?

    /// Forwarder tasks pulling from the active child's streams. Cancelled
    /// and restarted whenever the active child changes or the router
    /// stops.
    private var forwarderTasks: [Task<Void, Never>] = []

    /// Last requested identity. Remembered so a `select(_:)` mid-session
    /// can restart the new child with the same parameters.
    private var lastDisplayName: String?
    private var lastRendezvousToken: String?

    /// Whether the router is currently "running" (started). Drives the
    /// restart-on-select behavior.
    private var isActive = false

    // MARK: Init

    init(
        multipeer: PayloadTransport,
        wifiAware: PayloadTransport? = nil,
        initialSelection: TransportSelection = .multipeer
    ) {
        self.multipeer = multipeer
        self.wifiAware = wifiAware
        self.selection = initialSelection

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
        lastDisplayName = displayName
        lastRendezvousToken = rendezvousToken
        isActive = true

        guard let child = activeChild() else {
            emitInactiveDiagnostics()
            return
        }
        cancelForwarders()
        startForwarders(for: child)
        child.start(displayName: displayName, rendezvousToken: rendezvousToken)
    }

    func stop() {
        isActive = false
        cancelForwarders()
        activeChild()?.stop()
        emitInactiveDiagnostics()
    }

    func send(_ data: Data, to peer: TransportPeerID) throws {
        guard let child = activeChild() else { throw TransportError.transportNotActive }
        try child.send(data, to: peer)
    }

    func broadcast(_ data: Data) {
        activeChild()?.broadcast(data)
    }

    /// Switch the active transport. If the router is currently running,
    /// stop the old child and start the new one with the same identity
    /// + rendezvous token. If not running, just remember the choice;
    /// the next `start(...)` uses it.
    func select(_ selection: TransportSelection) {
        guard selection != self.selection else { return }
        let wasActive = isActive
        let displayName = lastDisplayName
        let token = lastRendezvousToken

        cancelForwarders()
        activeChild()?.stop()

        self.selection = selection

        if wasActive, let displayName, let token, let child = activeChild() {
            startForwarders(for: child)
            child.start(displayName: displayName, rendezvousToken: token)
        } else {
            emitInactiveDiagnostics()
        }
    }

    // MARK: Internals

    private func activeChild() -> PayloadTransport? {
        switch selection {
        case .multipeer: return multipeer
        case .wifiAware: return wifiAware
        }
    }

    private func emitInactiveDiagnostics() {
        diagnosticsContinuation.yield(
            TransportDiagnostics(connectedPeers: 0, isActive: false, selection: selection)
        )
    }

    /// Pump the active child's three async streams into the router's
    /// own continuations. Each forwarder is a single Task; cancellation
    /// stops the pull immediately. Continuations themselves persist for
    /// the router's lifetime — consumers downstream see a single stable
    /// stream across transport swaps.
    private func startForwarders(for child: PayloadTransport) {
        let incomingCont = self.incomingContinuation
        let eventsCont = self.peerEventsContinuation
        let diagCont = self.diagnosticsContinuation
        let currentSelection = self.selection

        forwarderTasks = [
            Task { [incoming = child.incoming] in
                for await packet in incoming {
                    incomingCont.yield(packet)
                }
            },
            Task { [peerEvents = child.peerEvents] in
                for await event in peerEvents {
                    eventsCont.yield(event)
                }
            },
            Task { [diagnostics = child.diagnostics] in
                for await diag in diagnostics {
                    // Re-stamp the selection so downstream readers always
                    // see the router's view, not the child's.
                    var rewritten = diag
                    rewritten.selection = currentSelection
                    diagCont.yield(rewritten)
                }
            }
        ]
    }

    private func cancelForwarders() {
        for task in forwarderTasks { task.cancel() }
        forwarderTasks.removeAll()
    }
}

//
//  UWBSessionService.swift
//  GroupIn
//
//  Wraps `NearbyInteraction` for peer-to-peer UWB precision finding.
//  Each `NISession` runs against one peer, identified by an
//  `NIDiscoveryToken` exchanged out-of-band (in our case, via CloudKit).
//  Updates flow through the `readings` async stream — distance in
//  metres, direction as a device-frame unit vector.
//
//  Hardware: requires iPhone 11 or later (U1/U2 chip). Apps without UWB
//  hardware silently no-op via `isSupported = false`; the compass view
//  falls back to its existing GPS/RSSI paths.
//

import Foundation
import NearbyInteraction
import simd

struct UWBReading: Sendable {
    let memberID: UUID
    /// Distance in metres. Apple guarantees centimeter-grade accuracy
    /// when both phones are roughly pointed at each other.
    let distance: Float?
    /// Unit vector toward the peer in device coordinates: x = right of
    /// screen, y = above screen, z = out of screen toward user.
    let direction: SIMD3<Float>?
    let timestamp: Date
}

@MainActor
protocol UWBSessionServicing: AnyObject {
    var readings: AsyncStream<UWBReading> { get }
    /// NSKeyedArchiver-encoded NIDiscoveryToken for the local session.
    /// Nil before `start()` runs or on devices without UWB hardware.
    var localTokenData: Data? { get }
    var isSupported: Bool { get }
    func start()
    func stop()
    /// Open a UWB session targeting this peer with their decoded token.
    /// Idempotent — reusing the same memberID/token is a no-op.
    func track(memberID: UUID, tokenData: Data)
    func untrack(memberID: UUID)
}

@MainActor
final class UWBSessionService: NSObject, UWBSessionServicing {

    let readings: AsyncStream<UWBReading>
    private nonisolated let readingsContinuation: AsyncStream<UWBReading>.Continuation

    private var localSession: NISession?
    private var peerSessions: [UUID: NISession] = [:]
    /// Used to look up the memberID for a given session inside delegate
    /// callbacks without hauling non-Sendable NISession references
    /// across actor boundaries.
    private var memberIDByObjectID: [ObjectIdentifier: UUID] = [:]

    private(set) var localTokenData: Data?

    var isSupported: Bool {
        Self.deviceSupportsUWB()
    }

    /// Static probe of UWB hardware. Mirrors `WiFiAwareService
    /// .deviceSupportsWiFiAware()` so capability building doesn't have
    /// to instantiate a session just to read the support bit.
    nonisolated static func deviceSupportsUWB() -> Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: UWBReading.self)
        self.readings = stream
        self.readingsContinuation = continuation
        super.init()
    }

    func start() {
        guard isSupported else { return }
        guard localSession == nil else { return }

        let session = NISession()
        session.delegate = self
        localSession = session

        if let token = session.discoveryToken {
            localTokenData = Self.encode(token)
        }
    }

    func stop() {
        localSession?.invalidate()
        localSession = nil
        for session in peerSessions.values {
            session.invalidate()
        }
        peerSessions.removeAll()
        memberIDByObjectID.removeAll()
        localTokenData = nil
    }

    func track(memberID: UUID, tokenData: Data) {
        guard isSupported else { return }
        guard peerSessions[memberID] == nil else { return }
        guard let token = Self.decode(tokenData) else { return }

        let session = NISession()
        session.delegate = self
        let config = NINearbyPeerConfiguration(peerToken: token)
        session.run(config)
        peerSessions[memberID] = session
        memberIDByObjectID[ObjectIdentifier(session)] = memberID
    }

    func untrack(memberID: UUID) {
        guard let session = peerSessions.removeValue(forKey: memberID) else { return }
        memberIDByObjectID.removeValue(forKey: ObjectIdentifier(session))
        session.invalidate()
    }

    // MARK: - Token codec

    private static func encode(_ token: NIDiscoveryToken) -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
    }

    private static func decode(_ data: Data) -> NIDiscoveryToken? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NIDiscoveryToken.self,
            from: data
        )
    }
}

extension UWBSessionService: NISessionDelegate {

    nonisolated func session(_ session: NISession,
                             didUpdate nearbyObjects: [NINearbyObject]) {
        // Extract just the value-typed data we need before hopping
        // actors — NINearbyObject is a class and not Sendable.
        let sessionKey = ObjectIdentifier(session)
        let payload: [(distance: Float?, direction: SIMD3<Float>?)] =
            nearbyObjects.map { ($0.distance, $0.direction) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let memberID = self.memberIDByObjectID[sessionKey] else { return }
            for sample in payload {
                self.readingsContinuation.yield(
                    UWBReading(
                        memberID: memberID,
                        distance: sample.distance,
                        direction: sample.direction,
                        timestamp: .now
                    )
                )
            }
        }
    }

    nonisolated func session(_ session: NISession,
                             didInvalidateWith error: Error) {
        let sessionKey = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let memberID = self.memberIDByObjectID.removeValue(forKey: sessionKey) {
                self.peerSessions.removeValue(forKey: memberID)
            }
            // Local session can also be invalidated (e.g., user revoked
            // location); clear local token if so.
            if self.localSession.map({ ObjectIdentifier($0) }) == sessionKey {
                self.localSession = nil
                self.localTokenData = nil
            }
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        // iOS auto-suspends NISessions when the app backgrounds.
        // Resume happens automatically on foreground; nothing to do.
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        // Nothing to do — NI delivers fresh updates on its own once
        // the session resumes.
    }
}

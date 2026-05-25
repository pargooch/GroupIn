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
    /// The member we're currently running a peer ranging configuration
    /// against, or nil. Debug-only readout — confirms `track` actually
    /// fired (i.e. the peer's token was received and a session opened).
    var trackedMemberID: UUID? { get }
    var hasLiveSession: Bool { get }
    var cameraAssistanceActive: Bool { get }
    var debugRunCount: Int { get }
    var debugUpdateCount: Int { get }
    var debugRangedCount: Int { get }
    var debugLastInvalidation: String? { get }
    /// Enable/disable camera-assisted UWB (direction). NISession owns its
    /// own ARSession; do not run a separate VIO ARSession alongside.
    func setCameraAssistance(_ enabled: Bool)
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

    /// The single NISession. Its `discoveryToken` is what we broadcast,
    /// AND it is the session we run the peer's `NINearbyPeerConfiguration`
    /// on — those MUST be the same session for the two devices to
    /// rendezvous. NINearbyPeerConfiguration is strictly 1:1, so the
    /// compass ranges one peer at a time; switching targets re-runs the
    /// config on this same session.
    private var localSession: NISession?
    /// The member the running peer-configuration currently targets, or
    /// nil when we're not ranging anyone.
    private var activeMemberID: UUID?
    /// Token the current config was opened against — lets `track` detect
    /// a no-op (same peer + token) vs. a real change (peer relaunched →
    /// new token, or a different target).
    private var activeToken: Data?

    /// Camera assistance makes UWB surface a DIRECTION vector (the AirTag
    /// arrow), not just distance. Toggled by the compass (indoor + open).
    /// NISession manages its OWN ARSession — we do NOT run a separate VIO
    /// ARSession, which is what conflicted and threw
    /// NIERROR_INVALID_AR_SESSION_DESCRIPTION on these devices before.
    private var cameraAssistanceWanted = false
    /// Latched true on the FIRST camera-assist AR failure. From then on we
    /// fall back to raw ranging for the whole session — no retry, no
    /// reconfigure churn (that churn is what kept killing UWB).
    private var cameraAssistanceFailed = false

    // Watchdog state. NISession often comes up "wedged" on a fresh launch
    // (configured, no invalidation, but never delivers) — the reason UWB
    // "needs a relaunch". The watchdog detects a silent-but-tracking
    // session and rebuilds it automatically so the user never has to
    // close + reopen the app.
    private var lastReadingAt: Date?
    private var lastTrackAt: Date = .distantPast
    private var lastRecoverAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    private static let watchdogSilenceThreshold: TimeInterval = 6
    private static let watchdogCheckInterval: TimeInterval = 2

    private(set) var localTokenData: Data?

    // Debug diagnostics for the asymmetric-ranging investigation.
    private(set) var debugRunCount = 0          // times we called session.run
    private(set) var debugUpdateCount = 0       // didUpdate delegate calls
    private(set) var debugRangedCount = 0       // nearbyObjects w/ a distance
    private(set) var debugLastInvalidation: String?

    var trackedMemberID: UUID? { activeMemberID }
    var hasLiveSession: Bool { localSession != nil }
    /// Whether camera assistance is actually being applied right now
    /// (wanted, not latched-failed, hardware supports it).
    var cameraAssistanceActive: Bool { cameraAssistanceEffective }
    private var cameraAssistanceEffective: Bool {
        cameraAssistanceWanted && !cameraAssistanceFailed
            && Self.deviceSupportsCameraAssistance()
    }

    var isSupported: Bool {
        Self.deviceSupportsUWB()
    }

    /// Static probe of UWB hardware. Mirrors `WiFiAwareService
    /// .deviceSupportsWiFiAware()` so capability building doesn't have
    /// to instantiate a session just to read the support bit.
    nonisolated static func deviceSupportsUWB() -> Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    nonisolated static func deviceSupportsCameraAssistance() -> Bool {
        NISession.deviceCapabilities.supportsCameraAssistance
    }

    /// Toggle camera assistance (direction). Re-runs the active peer
    /// config so it takes effect immediately. NISession owns the camera;
    /// no separate ARSession.
    func setCameraAssistance(_ enabled: Bool) {
        guard enabled != cameraAssistanceWanted else { return }
        cameraAssistanceWanted = enabled
        if let session = localSession, let tokenData = activeToken,
           let token = Self.decode(tokenData) {
            runConfig(on: session, peerToken: token)
        }
    }

    /// Build + run the peer config with the current camera-assist setting.
    private func runConfig(on session: NISession, peerToken: NIDiscoveryToken) {
        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        config.isCameraAssistanceEnabled = cameraAssistanceEffective
        session.run(config)
        debugRunCount += 1
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
        startWatchdog()
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        localSession?.invalidate()
        localSession = nil
        activeMemberID = nil
        activeToken = nil
        localTokenData = nil
        lastReadingAt = nil
        cameraAssistanceWanted = false
        // Keep `cameraAssistanceFailed` latched across stop/start within a
        // launch — if it failed once, it'll fail again; don't churn.
    }

    /// Periodically rebuild a tracking-but-silent NISession. This is what
    /// removes the "I have to close and reopen the app" UWB crankiness:
    /// on a fresh launch the session frequently comes up configured but
    /// never delivers (no error), and only a relaunch fixed it. Here we
    /// detect that (tracking, but no reading for a while) and recreate the
    /// session + re-track automatically. Self-stops churning once readings
    /// flow (lastReadingAt stays fresh).
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogCheckInterval))
                guard let self else { return }
                guard self.activeMemberID != nil else { continue }
                let now = Date()
                // Give a freshly-run config time to establish first.
                guard now.timeIntervalSince(self.lastTrackAt) > Self.watchdogSilenceThreshold,
                      now.timeIntervalSince(self.lastRecoverAt) > Self.watchdogSilenceThreshold
                else { continue }
                let silent = self.lastReadingAt
                    .map { now.timeIntervalSince($0) > Self.watchdogSilenceThreshold } ?? true
                guard silent else { continue }
                self.recoverWedgedSession()
            }
        }
    }

    /// Rebuild the local session (fresh token) and re-track the current
    /// peer. The new token is republished by AppState's periodic
    /// broadcast, so the peer re-reads it and re-tracks → bilateral
    /// re-sync, ranging resumes.
    private func recoverWedgedSession() {
        guard let memberID = activeMemberID, let tokenData = activeToken else { return }
        lastRecoverAt = Date()
        lastReadingAt = nil
        localSession?.invalidate()
        let session = NISession()
        session.delegate = self
        localSession = session
        localTokenData = session.discoveryToken.flatMap(Self.encode)
        // Clear so `track` re-runs (it no-ops on an unchanged peer+token).
        activeMemberID = nil
        activeToken = nil
        track(memberID: memberID, tokenData: tokenData)
    }

    func track(memberID: UUID, tokenData: Data) {
        guard isSupported else { return }
        guard let token = Self.decode(tokenData) else { return }

        // Ensure our token-bearing session is up (it normally is — BLE
        // presence calls `start()` — but be defensive).
        if localSession == nil { start() }
        guard let session = localSession else { return }

        // No-op if we're already ranging this exact peer + token. A peer
        // who relaunched hands us a *new* token (NIDiscoveryToken
        // regenerates per launch); that falls through and re-runs.
        if activeMemberID == memberID, activeToken == tokenData {
            return
        }

        // THE FIX: run the peer configuration on the SAME session whose
        // discoveryToken we broadcast. The peer runs their config against
        // our shared token while we run ours against theirs, so the two
        // sessions rendezvous and ranging begins. (The previous code ran
        // the config on a throwaway session whose token was never shared,
        // leaving both devices configured against idle/mismatched
        // sessions — UWB produced nothing, ever.) Re-running replaces any
        // prior target, so switching who we seek just works. `runConfig`
        // applies camera assistance when it's enabled + supported.
        runConfig(on: session, peerToken: token)
        activeMemberID = memberID
        activeToken = tokenData
        lastTrackAt = Date()
    }

    func untrack(memberID: UUID) {
        guard activeMemberID == memberID else { return }
        activeMemberID = nil
        activeToken = nil
        // Recreate a clean session so a fresh local token stays available
        // for the next target without continuing to range the dropped
        // peer. (NISession has no "stop ranging but keep the session"
        // primitive, so we cycle it.)
        localSession?.invalidate()
        let session = NISession()
        session.delegate = self
        localSession = session
        localTokenData = session.discoveryToken.flatMap(Self.encode)
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
            // Count EVERY delivery (before any guard) so the debug panel
            // can distinguish "session never fires" from "fires but we
            // drop it" / "fires with nil distance".
            self.debugUpdateCount += 1
            if payload.contains(where: { $0.distance != nil }) {
                self.debugRangedCount += 1
            }
            // Only our live session carries the current target; ignore
            // stray callbacks from an invalidated one.
            guard let local = self.localSession,
                  ObjectIdentifier(local) == sessionKey,
                  let memberID = self.activeMemberID else { return }
            self.lastReadingAt = Date()   // feeds the wedged-session watchdog
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
        let reason = error.localizedDescription
        // Camera-assist failures show up as an AR-session error. Detect so
        // we permanently fall back to RAW ranging instead of dying.
        let arProblem = reason.contains("AR_SESSION") || reason.contains("ARSession")
            || reason.localizedCaseInsensitiveContains("camera")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.debugLastInvalidation = reason
            guard let local = self.localSession,
                  ObjectIdentifier(local) == sessionKey else { return }
            let memberID = self.activeMemberID
            let tokenData = self.activeToken
            self.localSession = nil
            self.localTokenData = nil
            self.activeMemberID = nil
            self.activeToken = nil
            if arProblem {
                // Latch camera assistance OFF for the session — it can't
                // run on this device. Recovery below re-tracks RAW, which
                // won't re-invalidate, so there's no loop/churn.
                self.cameraAssistanceFailed = true
            }
            // Recover: recreate the session + token and re-track (raw now
            // if camera assist latched off). New token is republished by
            // AppState's broadcast; the peer re-reads + re-tracks.
            self.start()
            if let memberID, let tokenData {
                self.track(memberID: memberID, tokenData: tokenData)
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

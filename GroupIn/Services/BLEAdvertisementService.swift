//
//  BLEAdvertisementService.swift
//  GroupIn
//
//  Foreground BLE peer presence over CoreBluetooth. Each device runs both
//  peripheral and central:
//
//    - As a peripheral: advertises a GroupIn service UUID and exposes one
//      readable + notifiable characteristic carrying the local
//      `PeerPresence` JSON.
//    - As a central: scans for the same service UUID, connects to any
//      discovered peer, reads the characteristic once for current state,
//      then subscribes to notifications and stays connected. Updates to
//      a peer's presence push instantly via BLE notify (sub-second) instead
//      of being polled.
//
//  Phase 1 scope: foreground only. iOS heavily restricts background BLE
//  for arbitrary apps; the strong-background story comes when paired to a
//  dedicated MagSafe accessory (see docs/MAGSAFE.md).
//

import Foundation
import CoreBluetooth
import CoreLocation
import UIKit

/// One RSSI sample for a known peer. Emitted on every BLE scan callback
/// for peripherals we've already mapped to a member ID via a prior GATT
/// read. Used by the compass's gradient mode.
struct RSSIReading: Sendable {
    let memberID: UUID
    let rssi: Double
    let timestamp: Date
}

/// A peer's UWB discovery token, read from their dedicated nearby-token
/// GATT characteristic. Carried separately from `PeerPresence` because
/// the archived token (~530 bytes base64) blows past the ~512-byte ATT
/// characteristic read limit when stuffed into the presence JSON.
struct NearbyTokenUpdate: Sendable {
    let memberID: UUID
    let tokenData: Data
}

@MainActor
protocol BLEPresenceServicing: AnyObject {
    var peerUpdates: AsyncStream<PeerPresence> { get }
    var rssiUpdates: AsyncStream<RSSIReading> { get }
    /// A peer's UWB discovery token arriving over its own GATT
    /// characteristic. Drives `UWBSessionService.track`.
    var nearbyTokenUpdates: AsyncStream<NearbyTokenUpdate> { get }

    /// JoinResponse payloads received from in-range peers while in
    /// discovery mode. AppState consumes these to short-circuit the
    /// CloudKit `joinGroup` round-trip when an in-range member can
    /// answer faster.
    var joinResponses: AsyncStream<JoinResponse> { get }

    /// Incoming `JoinRequest`s written to our `joinRequest`
    /// characteristic by nearby central peers looking to join.
    /// AppState validates the request (invite-code match, banlist)
    /// and decides whether to call `respondToJoinRequest`.
    var incomingJoinRequests: AsyncStream<JoinRequest> { get }

    /// Incoming `SeekingSignal`s — a nearby central wrote one to
    /// our `seekingSignal` characteristic to say they're actively
    /// trying to find us. AppState consumes these to ramp our
    /// presence broadcast cadence while the signal is unexpired.
    var incomingSeekingSignals: AsyncStream<SeekingSignal> { get }

    /// Stream of diagnostics about the BLE pipe.
    var diagnostics: AsyncStream<BLEDiagnostics> { get }

    func start(groupHash: UInt32, localPresence: PeerPresence)
    func update(localPresence: PeerPresence)
    /// Publish our local UWB discovery token (raw archived bytes) on the
    /// dedicated nearby-token characteristic so in-range peers can read
    /// it and open a NISession against us. Pass nil to clear. Stable for
    /// the session, so it doesn't churn like presence.
    func updateNearbyToken(_ data: Data?)
    func stop()

    /// Enter join-discovery mode: scan + connect to nearby GroupIn
    /// peripherals, write the provided `JoinRequest` to each, and
    /// emit any `JoinResponse` replies onto `joinResponses`. Call
    /// even when the user isn't in a group yet — the BLE service
    /// starts its central up if it isn't already running.
    func startJoinDiscovery(_ request: JoinRequest)

    /// Cancel join discovery — no more JoinRequest writes, queued
    /// peripherals get cancelled. Idempotent.
    func stopJoinDiscovery()

    /// Broadcast a `JoinResponse` to all currently-subscribed
    /// centrals on the joinResponse characteristic. Joiners filter
    /// by invite code on receive, so a broadcast that hits the
    /// wrong central is harmlessly ignored. Called by AppState
    /// after it validates a `JoinRequest` against the active group.
    func respondToJoinRequest(_ response: JoinResponse)

    /// Register a single callback that fires when a `JoinResponse`
    /// arrives. Pass `nil` to deregister. Used by AppState's join
    /// awaiter — strictly single-consumer so retries don't race on a
    /// shared AsyncStream's iterators. The handler is replaced atomically;
    /// only the most recently registered one ever fires.
    func setJoinResponseHandler(_ handler: ((JoinResponse) -> Void)?)

    /// Start polling `readRSSI()` on the live GATT connection for the
    /// given member at 5 Hz. Used by the BLE seeking channel — gives
    /// us active RSSI samples that work even when the peer is
    /// backgrounded, with much higher density than passive scan
    /// callbacks (which iOS throttles). Idempotent.
    func startActiveRSSIPolling(for memberID: UUID)

    /// Stop the polling Task for a member. Idempotent.
    func stopActiveRSSIPolling(for memberID: UUID)

    /// Write a `SeekingSignal` to the peer's
    /// `seekingSignal` characteristic. Caller is responsible for
    /// refreshing on a cadence so the signal doesn't expire mid-
    /// session — `expiresAt` should be a few seconds in the future.
    /// Idempotent in the sense that an extra write is harmless.
    func sendSeekingSignal(_ signal: SeekingSignal, to memberID: UUID)
}

struct BLEDiagnostics: Sendable, Equatable {
    var presenceSubscribers: Int
    var serviceAddFailed: Bool
    /// True when both BLE roles report `.poweredOn`. Optimistic at app
    /// launch so we don't flash a "Bluetooth is off" banner before iOS
    /// has reported the real state. Driven down to false the moment
    /// either manager sees `.poweredOff` / `.unauthorized` / `.unsupported`.
    var bluetoothReady: Bool = true

    /// Central-side observability — populated as we scan, connect, and
    /// map peripherals to member IDs. The UI uses these to tell the
    /// user which stage of the pipeline is stuck when RSSI samples
    /// never arrive ("seen but not connected", "connected but not
    /// mapped", etc).
    var discoveredPeripheralCount: Int = 0
    var connectedPeripheralCount: Int = 0
    /// Connected peripherals that completed GATT service+characteristic
    /// discovery. The gap between `connectedPeripheralCount` and this
    /// field is "connected but discovery stalled" — typically a stale
    /// GATT cache or a link that came up before encryption finished.
    var servicesDiscoveredCount: Int = 0
    var mappedMemberCount: Int = 0
    /// Total RSSI samples yielded per memberID since the service last
    /// started. Reset on `stop()`. Useful for confirming that scan
    /// callbacks are still arriving for a known peer.
    var rssiSampleCountByMember: [UUID: Int] = [:]
    /// Most recent RSSI sample timestamp per memberID. Lets the UI
    /// show "last sample 0.4s ago" without exposing the full buffer.
    var lastRSSITimestampByMember: [UUID: Date] = [:]

    /// Debug instrumentation for the GATT presence-read pipeline — pins
    /// down exactly where presence delivery breaks: did the read deliver
    /// bytes at all, did they decode, and did the group-hash check pass.
    var presenceReadCallbacks: Int = 0
    var presenceReadBytes: Int = 0
    var presenceSentBytes: Int = 0
    var presenceDecodeFailures: Int = 0
    var presenceGroupHashMismatches: Int = 0
    var presenceDelivered: Int = 0
}

@MainActor
final class BLEAdvertisementService: NSObject, BLEPresenceServicing {

    // MARK: - GATT identifiers

    /// Service UUID — distinguishes GroupIn from any other BLE peripheral.
    /// Centrals filter scans on this so we don't see every random AirPod.
    static let serviceUUID = CBUUID(string: "A5B7E1C0-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Characteristic UUID for the JSON-encoded PeerPresence payload.
    static let presenceCharacteristicUUID = CBUUID(string: "A5B7E1C1-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Joiner-side writes a JSON-encoded `JoinRequest` here. The peer
    /// validates the invite code against its active group and (on
    /// match) responds via the joinResponse characteristic.
    static let joinRequestCharacteristicUUID = CBUUID(string: "A5B7E1C4-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Peer-side notifies a `JoinResponse` back to the requesting
    /// central. Targets only the requester (not broadcast) so other
    /// in-range centrals don't pick up someone else's join answer.
    static let joinResponseCharacteristicUUID = CBUUID(string: "A5B7E1C5-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Seekers write a `SeekingSignal` here to tell us they're
    /// actively trying to find us. We use the freshness to ramp our
    /// presence broadcast cadence (default GPS-tick rate → 10 Hz
    /// for 10 s → 2 Hz for 20 s → back to default).
    static let seekingSignalCharacteristicUUID = CBUUID(string: "A5B7E1C6-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Carries the raw NSKeyedArchiver-encoded `NIDiscoveryToken` for
    /// UWB. Its own characteristic (separate from presence) because the
    /// token is large (~400 bytes raw) and stable — keeping it out of the
    /// frequently-mutating, size-capped presence packet is what lets both
    /// the presence AND the token actually transfer.
    static let nearbyTokenCharacteristicUUID = CBUUID(string: "A5B7E1C7-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// iBeacon UUID for region monitoring. Different from the BLE service
    /// UUID because iBeacon advertisements use a manufacturer-data format
    /// while BLE service advertisements use the service-UUID list — iOS
    /// only lets us advertise one mode at a time, so the peripheral
    /// alternates between the two below.
    static let iBeaconUUID = UUID(uuidString: "1A7B5F30-9E2C-4D3B-8A5F-2C9D7E1A4F5B")!

    /// Restoration identifier for the central manager. Required for
    /// iOS to relaunch the app (or wake it from suspension) when our
    /// BLE service UUID is detected while we're not running. Paired
    /// with the `bluetooth-central` background mode.
    static let centralRestoreIdentifier = "groupin.central.v1"

    /// Restoration identifier for the peripheral manager. Lets iOS
    /// resume our advertising / GATT serving in background. Paired
    /// with the `bluetooth-peripheral` background mode.
    static let peripheralRestoreIdentifier = "groupin.peripheral.v1"

    // MARK: - Streams

    let peerUpdates: AsyncStream<PeerPresence>
    let rssiUpdates: AsyncStream<RSSIReading>
    let nearbyTokenUpdates: AsyncStream<NearbyTokenUpdate>
    let joinResponses: AsyncStream<JoinResponse>
    let incomingJoinRequests: AsyncStream<JoinRequest>
    let incomingSeekingSignals: AsyncStream<SeekingSignal>
    let diagnostics: AsyncStream<BLEDiagnostics>
    private nonisolated let peerContinuation: AsyncStream<PeerPresence>.Continuation
    private nonisolated let rssiContinuation: AsyncStream<RSSIReading>.Continuation
    private nonisolated let nearbyTokenContinuation: AsyncStream<NearbyTokenUpdate>.Continuation
    private nonisolated let joinResponseContinuation: AsyncStream<JoinResponse>.Continuation
    private nonisolated let incomingJoinRequestContinuation: AsyncStream<JoinRequest>.Continuation
    private nonisolated let incomingSeekingSignalContinuation: AsyncStream<SeekingSignal>.Continuation
    private nonisolated let diagnosticsContinuation: AsyncStream<BLEDiagnostics>.Continuation

    private var currentDiagnostics = BLEDiagnostics(
        presenceSubscribers: 0,
        serviceAddFailed: false,
        bluetoothReady: true
    )

    // MARK: - Stack

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    private var presenceCharacteristic: CBMutableCharacteristic?
    private var joinRequestCharacteristic: CBMutableCharacteristic?
    private var joinResponseCharacteristic: CBMutableCharacteristic?
    private var seekingSignalCharacteristic: CBMutableCharacteristic?
    private var nearbyTokenCharacteristic: CBMutableCharacteristic?
    /// Our local UWB token (raw archived bytes) served on the nearby-token
    /// characteristic. Set via `updateNearbyToken`.
    private var lastNearbyTokenData: Data?

    /// Recent JoinResponses we've emitted, kept so we can replay them
    /// to centrals that subscribe AFTER we already responded.
    /// CoreBluetooth has no "send to specific central across
    /// subscriptions" — `updateValue` only reaches currently
    /// subscribed centrals — so if a joiner subscribes a beat later
    /// than they wrote the JoinRequest, our reply lands in the void.
    /// Replaying on subscribe closes that race window. Bounded so we
    /// don't keep growing while the app runs.
    private var recentJoinResponses: [(response: JoinResponse, sentAt: Date)] = []
    private static let recentJoinResponsesLimit = 8
    /// Replay a JoinResponse only if it was generated within this
    /// window. Beyond that the joiner has either landed via another
    /// channel or moved on.
    private static let joinResponseReplayWindow: TimeInterval = 30
    private var advertisedService: CBMutableService?
    private var serviceAdded: Bool = false

    /// Active invite code we're hunting for when in join-discovery
    /// mode. Set by `startJoinDiscovery`, cleared on first acceptance
    /// or `stopJoinDiscovery`. The central side uses this to write
    /// the JoinRequest into discovered peripherals; the peripheral
    /// side ignores it.
    private var pendingJoinRequest: JoinRequest?

    private var activeGroupHash: UInt32?
    private var localMemberID: UUID?
    private var lastPresenceData: Data?

    /// Toggles the peripheral's advertised packet between Phase-1 GATT
    /// discovery (service UUID) and Phase-3 region wake (iBeacon).
    /// Only runs while the app is backgrounded — foreground sessions
    /// advertise service-UUID continuously so the seeker side isn't
    /// blacked out for 4-second iBeacon windows.
    private var advertisingTask: Task<Void, Never>?
    private static let advertiseToggleInterval: TimeInterval = 4

    /// Whether the host app is currently in the foreground. Drives the
    /// advertise-mode choice: service-UUID continuously while foreground,
    /// alternating with iBeacon while background. Maintained by the
    /// `UIApplication.didBecomeActive` / `willResignActive` observers
    /// hooked in `init`.
    private var isForeground: Bool = true

    /// Peripherals we've called `connect()` on but haven't yet seen
    /// `didConnect`. Stored as a dict (not a Set of IDs) so we hold a
    /// strong reference to each `CBPeripheral` during the connection
    /// attempt — without it, iOS prints "API MISUSE: Cancelling
    /// connection for unused peripheral" and can drop the link
    /// before `didConnect` fires.
    private var connectingPeers: [UUID: CBPeripheral] = [:]

    /// Peripherals with established connections we're keeping open.
    /// Strong reference holds them so iOS doesn't drop the link.
    private var connectedPeers: [UUID: CBPeripheral] = [:]

    /// Maps CB peripheral identifier → group member UUID. Populated two
    /// ways: (a) connectionless, from the advertised LocalName token the
    /// instant we hear a sought peer (fast path for RSSI), and (b) from a
    /// successfully-read presence characteristic. Because (a) fills this
    /// BEFORE the GATT read, the presence-read retry must NOT key off this
    /// map — see `presenceReceivedPeripherals`.
    private var peripheralToMember: [UUID: UUID] = [:]

    /// Peripherals from which we've actually decoded a FULL presence packet
    /// over GATT (capabilities + nearbyToken + coords, not just the RSSI
    /// token). This — not `peripheralToMember` — gates the presence-read
    /// retry: the connectionless RSSI mapping fills `peripheralToMember`
    /// immediately, which previously made the retry think the read was
    /// done and skip it, so capability negotiation + the UWB token never
    /// arrived when the initial read failed.
    private var presenceReceivedPeripherals: Set<UUID> = []

    /// Peripherals from which we've received a non-empty UWB token over
    /// the dedicated token characteristic. Gates the token re-read retry
    /// (the initial read can fire before the peer published its token or
    /// before the peripheral→member mapping exists).
    private var nearbyTokenReceivedPeripherals: Set<UUID> = []

    /// Frozen copy of a dynamic characteristic's buffer for the duration
    /// of a multi-PDU Read Blob sequence, keyed by
    /// "centralUUID:characteristicUUID". Captured at offset 0; served for
    /// every later blob so a long read can't splice together two
    /// different versions of a mutating value.
    private var readSnapshots: [String: Data] = [:]

    /// Every CBPeripheral identifier we've ever seen via a scan callback
    /// this session. Distinct from `connectedPeers` (subset that
    /// completed a GATT connect) and `peripheralToMember` (subset whose
    /// presence packet decoded). The three counts together tell us
    /// which stage of the pipeline is failing.
    private var discoveredPeripherals: Set<UUID> = []

    /// Wall-clock time at which each peripheral connected. Used by
    /// `retryPresenceReadIfStuck` to give up after a grace window and
    /// re-read the presence characteristic — handles the case where
    /// the first read returned empty or the decode failed.
    private var connectTimestamps: [UUID: Date] = [:]
    private var presenceRetryTask: Task<Void, Never>?
    private static let presenceReadRetryDelay: TimeInterval = 3

    /// Peripherals whose service discovery has completed at least once
    /// in this session. Surfaces the gap between "GATT connected" and
    /// "characteristics ready" in the diagnostic strip — the most
    /// common silent failure between conn and map.
    private var servicesDiscoveredFor: Set<UUID> = []

    /// MemberIDs we're currently active-polling RSSI for. Maps to a
    /// running Task that fires `peripheral.readRSSI()` on a cadence.
    /// Driven by `startActiveRSSIPolling` / `stopActiveRSSIPolling`
    /// from the seeking channel layer.
    private var activeRSSITasks: [UUID: Task<Void, Never>] = [:]
    /// Polling interval for active GATT readRSSI() — 200ms = 5 Hz, the
    /// "compass open" cadence agreed in the seeking-tier design.
    private static let activeRSSIPollInterval: TimeInterval = 0.2

    /// Last time we yielded a diagnostics snapshot driven by an RSSI
    /// sample. RSSI callbacks fire many times per second; without this
    /// throttle the diagnostics stream would dominate the run loop.
    private var lastRSSIDiagnosticsEmit: Date = .distantPast
    private static let rssiDiagnosticsMinInterval: TimeInterval = 0.5

    // MARK: - Init

    override init() {
        let (peerStream, peerCont) = AsyncStream.makeStream(of: PeerPresence.self)
        let (rssiStream, rssiCont) = AsyncStream.makeStream(of: RSSIReading.self)
        let (tokenStream, tokenCont) = AsyncStream.makeStream(of: NearbyTokenUpdate.self)
        let (joinStream, joinCont) = AsyncStream.makeStream(of: JoinResponse.self)
        let (joinReqStream, joinReqCont) = AsyncStream.makeStream(of: JoinRequest.self)
        let (seekStream, seekCont) = AsyncStream.makeStream(of: SeekingSignal.self)
        let (diagStream, diagCont) = AsyncStream.makeStream(of: BLEDiagnostics.self)
        self.peerUpdates = peerStream
        self.rssiUpdates = rssiStream
        self.nearbyTokenUpdates = tokenStream
        self.joinResponses = joinStream
        self.incomingJoinRequests = joinReqStream
        self.incomingSeekingSignals = seekStream
        self.diagnostics = diagStream
        self.peerContinuation = peerCont
        self.rssiContinuation = rssiCont
        self.nearbyTokenContinuation = tokenCont
        self.joinResponseContinuation = joinCont
        self.incomingJoinRequestContinuation = joinReqCont
        self.incomingSeekingSignalContinuation = seekCont
        self.diagnosticsContinuation = diagCont
        super.init()
        // State restoration on both managers. When iOS wakes the app
        // because of a BLE event while we're suspended (or after
        // force-quit on iPhones where the system allows it), the
        // restored manager fires `willRestoreState` so we can rewire
        // peripherals + characteristics without losing the connection.
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    Self.centralRestoreIdentifier
            ]
        )
        self.peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey:
                    Self.peripheralRestoreIdentifier
            ]
        )

        // Seed foreground state from UIApplication and listen for
        // transitions. The advertise loop checks this flag to decide
        // whether to alternate with iBeacon (background) or stay on
        // service-UUID continuously (foreground).
        self.isForeground = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleForegroundChange(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleForegroundChange(false)
            }
        }
    }

    /// Re-pick the advertising strategy when the app's foreground
    /// state flips. Foreground: continuous service-UUID. Background:
    /// alternate with iBeacon so region monitoring on the peer can
    /// wake their suspended app.
    private func handleForegroundChange(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        guard peripheralManager.state == .poweredOn,
              activeGroupHash != nil else { return }
        // Restart the advertising loop in the new mode. Cancelling the
        // old task and starting fresh is cheap and avoids edge cases
        // where the toggle could end up on the wrong phase.
        advertisingTask?.cancel()
        advertisingTask = nil
        peripheralManager.stopAdvertising()
        beginAdvertisingIfReady()
    }

    /// Push a fresh snapshot of the diagnostics stream.
    private func emitDiagnostics() {
        diagnosticsContinuation.yield(currentDiagnostics)
    }

    // MARK: - Lifecycle

    func start(groupHash: UInt32, localPresence: PeerPresence) {
        activeGroupHash = groupHash
        localMemberID = localPresence.memberID
        update(localPresence: localPresence)
        // Force a fresh service registration on every start. Removing
        // and re-adding the GATT service makes iOS send a Service
        // Changed indication to any centrals that have us cached from
        // a prior build (e.g., before the chat characteristic existed).
        // Without this, the central's GATT cache holds the old service
        // definition through Bluetooth toggles, app reinstalls, even
        // reboots in some cases.
        if let svc = advertisedService,
           peripheralManager.state == .poweredOn {
            peripheralManager.remove(svc)
        }
        serviceAdded = false
        advertisedService = nil
        presenceCharacteristic = nil
        joinRequestCharacteristic = nil
        joinResponseCharacteristic = nil
        seekingSignalCharacteristic = nil
        nearbyTokenCharacteristic = nil
        pendingJoinRequest = nil
        beginScanIfReady()
        beginAdvertisingIfReady()
    }

    func update(localPresence: PeerPresence) {
        guard let data = localPresence.encoded() else { return }
        lastPresenceData = data
        currentDiagnostics.presenceSentBytes = data.count
        guard let char = presenceCharacteristic,
              peripheralManager.state == .poweredOn else { return }
        // Push to all subscribed centrals via BLE notify — fast path
        // (sub-second to peers with a live connection).
        peripheralManager.updateValue(
            data,
            for: char,
            onSubscribedCentrals: nil
        )
    }

    func updateNearbyToken(_ data: Data?) {
        // No-op on an unchanged token — this is called on every presence
        // broadcast (so the token gets published the moment the NISession
        // makes it available, even if it was nil at `start`), and the
        // token is stable, so we must not spam notifies.
        guard data != lastNearbyTokenData else { return }
        lastNearbyTokenData = data
        guard let data, let char = nearbyTokenCharacteristic,
              peripheralManager.state == .poweredOn else { return }
        // Best-effort notify to any subscribed central. Subscribers also
        // read it explicitly on discovery, so a dropped notify is fine.
        peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
    }

    func stop() {
        advertisingTask?.cancel()
        advertisingTask = nil
        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
        }
        for (_, peripheral) in connectedPeers {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeers.removeAll()
        connectingPeers.removeAll()
        peripheralToMember.removeAll()
        presenceReceivedPeripherals.removeAll()
        nearbyTokenReceivedPeripherals.removeAll()
        readSnapshots.removeAll()
        connectTimestamps.removeAll()
        presenceRetryTask?.cancel()
        presenceRetryTask = nil
        for task in activeRSSITasks.values { task.cancel() }
        activeRSSITasks.removeAll()
        discoveredPeripherals.removeAll()
        servicesDiscoveredFor.removeAll()
        recentJoinResponses.removeAll()
        joinResponseHandler = nil
        lastRSSIDiagnosticsEmit = .distantPast
        activeGroupHash = nil
        localMemberID = nil
        currentDiagnostics = BLEDiagnostics(
            presenceSubscribers: 0,
            serviceAddFailed: false,
            bluetoothReady: bluetoothBothPoweredOn()
        )
        emitDiagnostics()
    }

    /// Combined power-state check across both BLE roles. We need both
    /// peripheral and central up to be fully functional, so the banner
    /// reflects the AND of the two states.
    private func bluetoothBothPoweredOn() -> Bool {
        centralManager.state == .poweredOn
            && peripheralManager.state == .poweredOn
    }

    private func updateBluetoothReadiness() {
        let ready = bluetoothBothPoweredOn()
        guard currentDiagnostics.bluetoothReady != ready else { return }
        currentDiagnostics.bluetoothReady = ready
        emitDiagnostics()
    }

    // MARK: - Internal

    private func beginScanIfReady() {
        // Scan when we have either an active group (normal in-group
        // discovery) or a pending join request (offline join-by-BLE).
        // The join-discovery path bypasses the activeGroupHash gate
        // because the joiner isn't a member yet but still needs to
        // find in-range peers who are.
        guard centralManager.state == .poweredOn,
              activeGroupHash != nil || pendingJoinRequest != nil else { return }
        // `allowDuplicates: true` is essential for reconnect after a peer
        // drops out of range — without duplicate callbacks iOS won't notify
        // us again once the peer reappears. The dedup checks in
        // `considerConnect` handle the "already connected" case so the extra
        // callbacks aren't wasted work.
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func beginAdvertisingIfReady() {
        guard peripheralManager.state == .poweredOn,
              activeGroupHash != nil else { return }
        if !serviceAdded { setupService() }
        if isForeground {
            // Foreground: stay on service-UUID continuously so a
            // searching central can find us at any moment. Indoor
            // mode is unusable otherwise — the 4-second iBeacon
            // windows make both phones mutually invisible ~75% of
            // the time and starve the gradient regression of RSSI.
            startContinuousServiceAdvertisement()
        } else {
            // Background: alternate so suspended peers' region
            // monitors can detect the iBeacon and wake their app
            // to a foreground BLE state.
            startAlternatingAdvertisement()
        }
    }

    private func startContinuousServiceAdvertisement() {
        advertisingTask?.cancel()
        advertisingTask = nil
        peripheralManager.stopAdvertising()
        advertiseAsService()
    }

    /// Toggle the peripheral between the Phase-1 service-UUID packet and
    /// an iBeacon packet every few seconds. Centrals discover us via
    /// service-UUID scan; backgrounded peers' region monitors detect us
    /// via the iBeacon. iOS only allows one active advertisement at a
    /// time so we share the radio between the two purposes.
    private func startAlternatingAdvertisement() {
        advertisingTask?.cancel()
        advertisingTask = Task { [weak self] in
            var iBeaconPhase = false
            while !Task.isCancelled {
                guard let self else { break }
                iBeaconPhase.toggle()
                self.peripheralManager.stopAdvertising()
                if iBeaconPhase {
                    self.advertiseAsBeacon()
                } else {
                    self.advertiseAsService()
                }
                try? await Task.sleep(for: .seconds(Self.advertiseToggleInterval))
            }
        }
    }

    private func advertiseAsService() {
        var advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ]
        // Stamp our member token into the LocalName so a scanning peer
        // can attribute every scan-callback RSSI to *this* member WITHOUT
        // first completing a GATT connect + presence read. This is the
        // dense, connectionless RSSI source the indoor compass gradient
        // relies on; the GATT path (presence/identity/seeking-signal)
        // still runs, it's just no longer a prerequisite for ranging.
        // 4 hex chars (16-bit truncated member ID, same token as the
        // iBeacon minor) fits comfortably alongside the 128-bit service
        // UUID in the 31-byte advert. iOS honors LocalName in the
        // foreground advertisement, which is exactly when seeking runs.
        if let id = localMemberID {
            advertisement[CBAdvertisementDataLocalNameKey] =
                Self.localNameToken(for: id)
        }
        peripheralManager.startAdvertising(advertisement)
    }

    /// Render a member ID into the 4-hex-char advertisement LocalName
    /// token (its 16-bit truncation). Symmetric with
    /// `memberID(forLocalNameToken:)` on the scanning side.
    static func localNameToken(for memberID: UUID) -> String {
        String(format: "%04X", memberID.truncated16)
    }

    /// Parse an advertisement LocalName back into the 16-bit member
    /// token, or nil if it isn't one of ours.
    static func token(fromLocalName name: String) -> UInt16? {
        UInt16(name, radix: 16)
    }

    private func advertiseAsBeacon() {
        guard let groupHash = activeGroupHash else { return }
        // Major identifies the group (collapsed 32→16 bits). Minor
        // identifies *which member* is broadcasting, so the receiver can
        // surface "Kian is nearby" instead of a generic group nudge.
        // 16-bit minor space → ~65k IDs per group; collisions are
        // negligible at festival-group sizes.
        let major = CLBeaconMajorValue(Self.collapseGroupHash(groupHash))
        let minor: CLBeaconMinorValue
        if let id = localMemberID {
            minor = CLBeaconMinorValue(id.truncated16)
        } else {
            // Fallback before we know our own member ID — fall back to
            // the lower 16 bits of the group hash so the region still
            // matches and other peers can detect us.
            minor = CLBeaconMinorValue(groupHash & 0xFFFF)
        }
        let region = CLBeaconRegion(
            uuid: Self.iBeaconUUID,
            major: major,
            minor: minor,
            identifier: "com.NDE.GroupIn.peer"
        )
        let raw = region.peripheralData(withMeasuredPower: nil)
        if let dict = raw as? [String: Any] {
            peripheralManager.startAdvertising(dict)
        }
    }

    /// Collapse a 32-bit FNV hash into the 16-bit iBeacon major space.
    /// XOR-fold preserves contribution from both halves, unlike a plain
    /// truncation which would discard the upper half entirely.
    static func collapseGroupHash(_ hash: UInt32) -> UInt16 {
        UInt16((hash >> 16) & 0xFFFF) ^ UInt16(hash & 0xFFFF)
    }

    private func setupService() {
        let presence = CBMutableCharacteristic(
            type: Self.presenceCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,                  // dynamic value (required for read+notify)
            permissions: [.readable]
        )
        // Joiners write a JoinRequest here — write-only, no read /
        // notify because the joiner doesn't need to observe their own
        // request. Permissions writeable.
        let joinReqChar = CBMutableCharacteristic(
            type: Self.joinRequestCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        // Peers push a JoinResponse back here to the requesting
        // central. Notify so the central wakes on receipt; read so
        // the joiner can poll if they miss the notify timing window.
        let joinRespChar = CBMutableCharacteristic(
            type: Self.joinResponseCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        // Seekers write a SeekingSignal here to tell us we're being
        // actively tracked. Write-only — no need to read or notify
        // since the sender knows what they sent.
        let seekChar = CBMutableCharacteristic(
            type: Self.seekingSignalCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        // UWB discovery token — read+notify, dynamic value (served from
        // `lastNearbyTokenData` in `didReceiveRead`). Separate from
        // presence so the large, stable token doesn't bloat the
        // size-capped presence packet.
        let tokenChar = CBMutableCharacteristic(
            type: Self.nearbyTokenCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let svc = CBMutableService(type: Self.serviceUUID, primary: true)
        svc.characteristics = [presence, joinReqChar, joinRespChar, seekChar, tokenChar]
        peripheralManager.add(svc)
        presenceCharacteristic = presence
        joinRequestCharacteristic = joinReqChar
        joinResponseCharacteristic = joinRespChar
        seekingSignalCharacteristic = seekChar
        nearbyTokenCharacteristic = tokenChar
        advertisedService = svc
        serviceAdded = true
    }

    func startJoinDiscovery(_ request: JoinRequest) {
        pendingJoinRequest = request
        // Make sure scanning is on so we discover in-range peers
        // immediately. Peripheral advertising stays off — the joiner
        // isn't a group member yet so there's nothing to advertise.
        beginScanIfReady()
        // Walk currently-connected peers, write the JoinRequest to
        // any that have the joinRequest characteristic discovered
        // already. New discoveries will write via the discovery
        // callback below.
        for (_, peripheral) in connectedPeers {
            writeJoinRequestIfPossible(to: peripheral)
        }
    }

    func stopJoinDiscovery() {
        pendingJoinRequest = nil
    }

    func respondToJoinRequest(_ response: JoinResponse) {
        guard let char = joinResponseCharacteristic,
              let data = response.encoded() else { return }

        // Cache for replay-on-subscribe. The joiner's central may
        // subscribe a beat AFTER it wrote the JoinRequest (the two
        // GATT operations race when both go out from
        // `didDiscoverCharacteristicsFor`), so a broadcast right now
        // can reach an empty subscriber set. Cache + replay closes
        // the gap.
        recentJoinResponses.append((response, .now))
        if recentJoinResponses.count > Self.recentJoinResponsesLimit {
            recentJoinResponses.removeFirst(
                recentJoinResponses.count - Self.recentJoinResponsesLimit
            )
        }

        // Don't call updateValue while the manager isn't powered on
        // — CoreBluetooth logs "API MISUSE" and the call is a no-op
        // anyway. The replay-on-subscribe path picks up the cached
        // response once the manager comes online and the central
        // subscribes.
        guard peripheralManager.state == .poweredOn else { return }

        // updateValue to all currently-subscribed centrals — the
        // joiner filters by invite code on receive, so an unrelated
        // central in our `joinResponseCharacteristic` subscriber
        // set (rare, but possible if a third device is mid-discovery)
        // just sees a payload they discard.
        _ = peripheralManager.updateValue(
            data,
            for: char,
            onSubscribedCentrals: nil
        )
    }

    /// Write the pending JoinRequest to a connected peripheral's
    /// joinRequest characteristic if discovered. Called from both
    /// `startJoinDiscovery` (for already-connected peers) and from
    /// the central-side `didDiscoverCharacteristics` callback (for
    /// newly-connected peers).
    private func writeJoinRequestIfPossible(to peripheral: CBPeripheral) {
        guard let request = pendingJoinRequest,
              let data = request.encoded(),
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }),
              let char = service.characteristics?.first(where: {
                  $0.uuid == Self.joinRequestCharacteristicUUID
              })
        else { return }
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    // Chat + event characteristic queues are gone — they live on the
    // payload transport now. The remaining backpressure-prone path is
    // the JoinResponse broadcast, which uses a single best-effort
    // `updateValue` with no queue. If a joiner misses the notify they
    // fall back to reading the characteristic value directly.
    private func drainObsoleteQueues() {
        // No-op shim left in place to keep delegate hooks stable; if
        // a future characteristic adds backpressure, drain it here.
    }

    private func considerConnect(to peripheral: CBPeripheral) {
        // Connect when we either have an active group OR are
        // actively looking to join one. The latter path lets a
        // pre-group joiner reach in-range members to request the
        // group identity over BLE.
        guard activeGroupHash != nil || pendingJoinRequest != nil else { return }
        let id = peripheral.identifier
        if connectingPeers[id] != nil || connectedPeers[id] != nil { return }

        // Hold a strong reference to the peripheral while connect()
        // is in flight — iOS otherwise drops the connection.
        connectingPeers[id] = peripheral
        connectTimestamps[id] = Date()
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        // Connect-watchdog. CoreBluetooth's `connect()` has no
        // built-in timeout — if iOS never resolves the request
        // (peer briefly out of range, peripheral's CBPeripheralManager
        // in a bad state, system connection-queue backed up), neither
        // `didConnect` nor `didFailToConnect` ever fires. The slot
        // in `connectingPeers` stays forever, every subsequent scan
        // callback's `considerConnect` bails on the "already
        // connecting" check, and we end up `seen: 1, conn: 0` for
        // the rest of the session. After 10 s, cancel the request
        // and clear our state so the next scan callback can retry.
        Task { @MainActor [weak self, id] in
            try? await Task.sleep(for: .seconds(Self.connectWatchdogSeconds))
            guard let self else { return }
            guard self.connectingPeers[id] != nil,
                  self.connectedPeers[id] == nil else { return }
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.connectingPeers.removeValue(forKey: id)
            self.connectTimestamps.removeValue(forKey: id)
        }
    }

    private static let connectWatchdogSeconds: TimeInterval = 10

    private func cleanupPeer(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        connectingPeers.removeValue(forKey: id)
        connectedPeers.removeValue(forKey: id)
        connectTimestamps.removeValue(forKey: id)
        if servicesDiscoveredFor.remove(id) != nil {
            currentDiagnostics.servicesDiscoveredCount = servicesDiscoveredFor.count
        }
        currentDiagnostics.connectedPeripheralCount = connectedPeers.count
        emitDiagnostics()
        // A reconnect must re-read presence + token from scratch, so
        // forget that we'd received them from this peripheral.
        presenceReceivedPeripherals.remove(id)
        nearbyTokenReceivedPeripherals.remove(id)
        // Don't remove the peripheral→member mapping here; we want to
        // keep emitting RSSI for that member if their iBeacon advert is
        // still detectable while we wait for a fresh GATT reconnect.
    }

    private func handlePresenceData(_ data: Data, from peripheral: CBPeripheral) {
        guard let presence = PeerPresence.decoded(from: data) else {
            currentDiagnostics.presenceDecodeFailures += 1
            emitDiagnostics()
            return
        }
        // Active-group filter: drop connections to peers from other
        // groups. Skipped during join-discovery — we don't have an
        // activeGroupHash but we need to stay connected long enough
        // for the JoinResponse to arrive; the joinRequest write
        // already filters by invite-code match server-side.
        let isDiscoveryMode = activeGroupHash == nil && pendingJoinRequest != nil
        guard isDiscoveryMode || presence.groupHash == activeGroupHash else {
            // Different group — drop the connection so we don't keep a
            // pointless link open.
            currentDiagnostics.presenceGroupHashMismatches += 1
            centralManager.cancelPeripheralConnection(peripheral)
            peripheralToMember.removeValue(forKey: peripheral.identifier)
            currentDiagnostics.mappedMemberCount = peripheralToMember.count
            emitDiagnostics()
            return
        }
        // In discovery mode, we keep the connection alive but don't
        // yield presence to AppState — we have no active group to
        // associate it with. The joinResponse handler below is the
        // sole consumer of discovery-mode connections.
        guard !isDiscoveryMode else { return }
        // Now that we know which member this peripheral is, tag future
        // scan callbacks with their member ID for the RSSI stream.
        peripheralToMember[peripheral.identifier] = presence.memberID
        presenceReceivedPeripherals.insert(peripheral.identifier)
        currentDiagnostics.mappedMemberCount = peripheralToMember.count
        currentDiagnostics.presenceDelivered += 1
        emitDiagnostics()
        peerContinuation.yield(presence)
    }

    /// Decode an incoming JoinResponse off the wire and dispatch to
    /// the registered single handler. Each `setJoinResponseHandler`
    /// caller replaces the previous handler atomically, so retries
    /// can never race on the same delivery. The legacy `joinResponses`
    /// AsyncStream is still fed for backwards compat, but new code
    /// should use the handler.
    private func handleJoinResponseData(_ data: Data) {
        guard let response = JoinResponse.decoded(from: data) else { return }
        // Sanity: only deliver responses that match the invite code we
        // asked for. Discards crossed-wire responses if multiple
        // join attempts are in flight.
        guard let request = pendingJoinRequest,
              response.inviteCode == request.inviteCode else { return }
        joinResponseHandler?(response)
        joinResponseContinuation.yield(response)
    }

    private var joinResponseHandler: ((JoinResponse) -> Void)?

    func setJoinResponseHandler(_ handler: ((JoinResponse) -> Void)?) {
        joinResponseHandler = handler
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEAdvertisementService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.updateBluetoothReadiness()
            self?.beginScanIfReady()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // iOS handed us back the peripherals we had open when the app
        // was last suspended / terminated. Rewire each one as the
        // delegate so subsequent characteristic notifications land in
        // our handlers without us having to re-scan + reconnect.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            for peripheral in restored {
                peripheral.delegate = self
                self.connectedPeers[peripheral.identifier] = peripheral
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let rssiValue = RSSI.doubleValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Track every distinct peripheral we ever see — the
            // diagnostic strip uses this so the user can tell apart
            // "haven't seen them at all" from "seen but can't connect".
            let inserted = self.discoveredPeripherals.insert(peripheral.identifier).inserted
            if inserted {
                self.currentDiagnostics.discoveredPeripheralCount =
                    self.discoveredPeripherals.count
                self.emitDiagnostics()
            }
            // Connectionless member attribution: if this peripheral
            // isn't mapped yet, try to resolve it from the advertised
            // LocalName token against the members we're actively seeking.
            // This is what lets RSSI flow the instant we hear a peer,
            // with no GATT connect required — the fix for "mapped=0 →
            // zero RSSI → indoor compass never works."
            if self.peripheralToMember[peripheral.identifier] == nil,
               let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
               let memberID = self.engagedMember(forLocalName: localName) {
                self.peripheralToMember[peripheral.identifier] = memberID
                self.currentDiagnostics.mappedMemberCount = self.peripheralToMember.count
                self.emitDiagnostics()
            }
            // Emit an RSSI sample if we already know which member this
            // peripheral belongs to. The compass uses these for gradient
            // bearing computation when GPS isn't viable.
            if let memberID = self.peripheralToMember[peripheral.identifier] {
                let now = Date()
                self.rssiContinuation.yield(RSSIReading(
                    memberID: memberID,
                    rssi: rssiValue,
                    timestamp: now
                ))
                self.currentDiagnostics.rssiSampleCountByMember[memberID, default: 0] += 1
                self.currentDiagnostics.lastRSSITimestampByMember[memberID] = now
                // Throttle: RSSI scan callbacks fire many times/sec, but
                // the UI only needs an update every half-second.
                if now.timeIntervalSince(self.lastRSSIDiagnosticsEmit)
                    >= Self.rssiDiagnosticsMinInterval {
                    self.lastRSSIDiagnosticsEmit = now
                    self.emitDiagnostics()
                }
            }
            self.considerConnect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = peripheral.identifier
            self.connectingPeers.removeValue(forKey: id)
            self.connectedPeers[id] = peripheral
            self.connectTimestamps[id] = Date()
            self.currentDiagnostics.connectedPeripheralCount = self.connectedPeers.count
            self.emitDiagnostics()
            peripheral.discoverServices([Self.serviceUUID])
            self.schedulePresenceReadRetry()
        }
    }

    /// Periodically inspect connected peripherals. Any one that's been
    /// connected for more than `presenceReadRetryDelay` without ending
    /// up in `peripheralToMember` gets a fresh `readValue` against its
    /// presence characteristic. The initial read in
    /// `didDiscoverCharacteristicsFor` is best-effort — if it returns
    /// nil or the decode fails, no retry happens by default and RSSI
    /// samples for that peer are silently dropped forever.
    // MARK: - Seeking signal (central writes to sought peer's GATT)

    func sendSeekingSignal(_ signal: SeekingSignal, to memberID: UUID) {
        guard let data = signal.encoded() else { return }
        // Look up the connected peripheral mapped to this member ID.
        // If we don't have a live connection yet (still discovering),
        // the next mergeBLEPeer + connect cycle will trigger another
        // write from the caller's refresh timer — this is best-effort.
        guard let peripheralID = peripheralToMember.first(where: {
            $0.value == memberID
        })?.key,
              let peripheral = connectedPeers[peripheralID],
              let service = peripheral.services?.first(where: {
                  $0.uuid == Self.serviceUUID
              }),
              let char = service.characteristics?.first(where: {
                  $0.uuid == Self.seekingSignalCharacteristicUUID
              })
        else { return }
        // .withResponse so we know if the peer is actually reachable;
        // failures show up in `peripheral(_:didWriteValueFor:error:)`
        // but the caller's refresh loop covers transient failures by
        // re-writing every few seconds.
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    // MARK: - Active RSSI polling

    func startActiveRSSIPolling(for memberID: UUID) {
        guard activeRSSITasks[memberID] == nil else { return }
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pollActiveRSSI(for: memberID)
                try? await Task.sleep(
                    for: .seconds(Self.activeRSSIPollInterval)
                )
            }
        }
        activeRSSITasks[memberID] = task
    }

    func stopActiveRSSIPolling(for memberID: UUID) {
        activeRSSITasks[memberID]?.cancel()
        activeRSSITasks.removeValue(forKey: memberID)
    }

    /// Resolve an advertised LocalName token to one of the members we're
    /// actively seeking. Scoped to the engaged (actively-polled) set
    /// because that's exactly who we want gradient RSSI for, and it keeps
    /// the 16-bit-token collision space tiny (one or two peers, not the
    /// whole group). Returns nil for our own token or any unknown peer.
    private func engagedMember(forLocalName name: String) -> UUID? {
        guard let token = Self.token(fromLocalName: name) else { return nil }
        return activeRSSITasks.keys.first { $0.truncated16 == token }
    }

    private func pollActiveRSSI(for memberID: UUID) {
        // Read RSSI on EVERY connected peripheral mapped to this member,
        // not just the first. iOS rotates a peer's BLE address, so we can
        // hold several CBPeripheral handles for the same member and only
        // the live one(s) answer `readRSSI`. Targeting just the first
        // (often a stale/dead handle) was why RSSI dried up the moment we
        // GATT-connected — iOS throttles advert/scan callbacks for a
        // connected peripheral, so the active poll is the ONLY RSSI source
        // while connected, and it was aiming at the wrong handle. Each
        // result is attributed back to the member in `didReadRSSI`.
        for (peripheralID, mapped) in peripheralToMember where mapped == memberID {
            connectedPeers[peripheralID]?.readRSSI()
        }
    }

    private func schedulePresenceReadRetry() {
        if presenceRetryTask != nil { return }
        presenceRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.retryPresenceReadIfStuck()
                if self.connectedPeers.isEmpty { break }
            }
            self?.presenceRetryTask = nil
        }
    }

    private func retryPresenceReadIfStuck() {
        let now = Date()
        for (id, peripheral) in connectedPeers {
            let needPresence = !presenceReceivedPeripherals.contains(id)
            let needToken = !nearbyTokenReceivedPeripherals.contains(id)
            // Nothing left to fetch from this peer.
            guard needPresence || needToken else { continue }
            guard let since = connectTimestamps[id],
                  now.timeIntervalSince(since) >= Self.presenceReadRetryDelay
            else { continue }
            // Reset the timestamp so we only retry once per window.
            connectTimestamps[id] = now

            let service = peripheral.services?.first { $0.uuid == Self.serviceUUID }
            // If service discovery never completed (stale GATT cache, or
            // the link came up before encryption finished), re-discover.
            guard let service else {
                peripheral.delegate = self
                peripheral.discoverServices([Self.serviceUUID])
                continue
            }
            // Re-read whichever value we're still missing. The initial
            // read in `didDiscoverCharacteristicsFor` can fire before the
            // peer published its token / before the peripheral→member map
            // is set; without this retry the token (and thus UWB) would
            // never arrive.
            if needPresence,
               let char = service.characteristics?.first(where: {
                   $0.uuid == Self.presenceCharacteristicUUID
               }) {
                peripheral.readValue(for: char)
            }
            if needToken,
               let char = service.characteristics?.first(where: {
                   $0.uuid == Self.nearbyTokenCharacteristicUUID
               }) {
                peripheral.readValue(for: char)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            self?.cleanupPeer(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        // On accidental disconnect (peer went out of range), the next scan
        // hit will trigger a fresh connect.
        Task { @MainActor [weak self] in
            self?.cleanupPeer(peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEAdvertisementService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            if error == nil {
                if self.servicesDiscoveredFor.insert(id).inserted {
                    self.currentDiagnostics.servicesDiscoveredCount =
                        self.servicesDiscoveredFor.count
                    self.emitDiagnostics()
                }
            }
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == Self.serviceUUID {
                // Discover BOTH characteristics. The previous single-
                // entry filter silently dropped chat — sender pushed
                // notifies fine, but no peer ever subscribed because
                // the chat characteristic was never discovered.
                peripheral.discoverCharacteristics(
                    [Self.presenceCharacteristicUUID,
                     Self.joinRequestCharacteristicUUID,
                     Self.joinResponseCharacteristicUUID,
                     Self.seekingSignalCharacteristicUUID,
                     Self.nearbyTokenCharacteristicUUID],
                    for: service
                )
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            // Two-pass ordering — subscriptions FIRST, writes second.
            // The host's `respondToJoinRequest` uses
            // `updateValue(..., onSubscribedCentrals: nil)` which only
            // reaches centrals currently subscribed to the response
            // characteristic. If we wrote the JoinRequest before
            // subscribing to the response notify, the host would
            // respond into the void and the joiner would never see
            // the reply. Doing subscribes first closes most of that
            // race (the host-side replay-on-subscribe path closes the
            // remainder).
            for char in chars {
                switch char.uuid {
                case Self.presenceCharacteristicUUID:
                    // Initial read so we get the peer's current state right away.
                    peripheral.readValue(for: char)
                    // Subscribe for ongoing live updates pushed via notify.
                    peripheral.setNotifyValue(true, for: char)
                case Self.nearbyTokenCharacteristicUUID:
                    // Read the peer's UWB token + subscribe in case it
                    // arrives/changes after we connect (peer started its
                    // NISession a beat later).
                    peripheral.readValue(for: char)
                    peripheral.setNotifyValue(true, for: char)
                case Self.joinResponseCharacteristicUUID:
                    // Subscribe before any write goes out so we don't
                    // miss the host's JoinResponse notify.
                    peripheral.setNotifyValue(true, for: char)
                default:
                    break
                }
            }
            for char in chars {
                if char.uuid == Self.joinRequestCharacteristicUUID {
                    self.writeJoinRequestIfPossible(to: peripheral)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didReadRSSI RSSI: NSNumber,
                                error: Error?) {
        guard error == nil else { return }
        let rssiValue = RSSI.doubleValue
        let peripheralID = peripheral.identifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let memberID = self.peripheralToMember[peripheralID] else { return }
            let now = Date()
            // Same downstream as scan-callback RSSI — feeds straight
            // into the compass engine. The active path is just denser
            // and works while the peer is backgrounded.
            self.rssiContinuation.yield(RSSIReading(
                memberID: memberID,
                rssi: rssiValue,
                timestamp: now
            ))
            self.currentDiagnostics.rssiSampleCountByMember[memberID, default: 0] += 1
            self.currentDiagnostics.lastRSSITimestampByMember[memberID] = now
            if now.timeIntervalSince(self.lastRSSIDiagnosticsEmit)
                >= Self.rssiDiagnosticsMinInterval {
                self.lastRSSIDiagnosticsEmit = now
                self.emitDiagnostics()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let charUUID = characteristic.uuid
        let hadError = error != nil
        let data = characteristic.value
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Count every presence read/notify callback BEFORE the data
            // guard, so a read that errors or returns nil still shows up
            // — that's exactly the failure we're hunting.
            if charUUID == Self.presenceCharacteristicUUID {
                self.currentDiagnostics.presenceReadCallbacks += 1
                self.currentDiagnostics.presenceReadBytes = data?.count ?? -1
                if hadError {
                    self.currentDiagnostics.presenceDecodeFailures += 1
                }
                self.emitDiagnostics()
            }
            guard !hadError, let data else { return }
            switch charUUID {
            case Self.presenceCharacteristicUUID:
                self.handlePresenceData(data, from: peripheral)
            case Self.nearbyTokenCharacteristicUUID:
                self.handleNearbyTokenData(data, from: peripheral)
            case Self.joinResponseCharacteristicUUID:
                self.handleJoinResponseData(data)
            default:
                break
            }
        }
    }

    /// A peer's raw UWB token arrived on its dedicated characteristic.
    /// Attribute it to the member this peripheral maps to (via presence
    /// or the connectionless LocalName path) and forward upward so
    /// AppState can open a NISession against them. If we don't yet know
    /// who this peripheral is, drop it — the periodic re-read / notify
    /// will redeliver once the mapping lands.
    private func handleNearbyTokenData(_ data: Data, from peripheral: CBPeripheral) {
        guard !data.isEmpty,
              let memberID = peripheralToMember[peripheral.identifier] else { return }
        nearbyTokenReceivedPeripherals.insert(peripheral.identifier)
        nearbyTokenContinuation.yield(
            NearbyTokenUpdate(memberID: memberID, tokenData: data)
        )
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEAdvertisementService: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor [weak self] in
            self?.updateBluetoothReadiness()
            self?.beginAdvertisingIfReady()
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        // Rebind any restored services to our characteristic refs so
        // reads/writes that land before `start(...)` runs again still
        // resolve. iOS doesn't reissue `didAdd` for restored services.
        let services = dict[CBPeripheralManagerRestoredStateServicesKey]
            as? [CBMutableService] ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            for service in services where service.uuid == Self.serviceUUID {
                self.advertisedService = service
                self.serviceAdded = true
                for char in service.characteristics ?? [] {
                    guard let mutable = char as? CBMutableCharacteristic else { continue }
                    switch mutable.uuid {
                    case Self.presenceCharacteristicUUID:
                        self.presenceCharacteristic = mutable
                    case Self.joinRequestCharacteristicUUID:
                        self.joinRequestCharacteristic = mutable
                    case Self.joinResponseCharacteristicUUID:
                        self.joinResponseCharacteristic = mutable
                    case Self.seekingSignalCharacteristicUUID:
                        self.seekingSignalCharacteristic = mutable
                    case Self.nearbyTokenCharacteristicUUID:
                        self.nearbyTokenCharacteristic = mutable
                    default:
                        break
                    }
                }
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Backpressure path. Currently no characteristic queues need
        // draining (chat + events moved to the payload transport), so
        // this is a stub awaiting a future use.
        Task { @MainActor [weak self] in
            self?.drainObsoleteQueues()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentDiagnostics.serviceAddFailed = failed
            self.emitDiagnostics()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        let charUUID = characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            if charUUID == Self.presenceCharacteristicUUID {
                self.currentDiagnostics.presenceSubscribers += 1
                self.emitDiagnostics()
                // Push current presence right away so the subscriber
                // doesn't need to issue a separate read. The central's
                // initial read in `didDiscoverCharacteristicsFor` can
                // race with the subscription on flaky links and miss
                // its response — a fresh notify here guarantees the
                // peer gets the presence packet at least once.
                if let data = self.lastPresenceData,
                   let char = self.presenceCharacteristic,
                   self.peripheralManager.state == .poweredOn {
                    self.peripheralManager.updateValue(
                        data,
                        for: char,
                        onSubscribedCentrals: [central]
                    )
                }
            } else if charUUID == Self.joinResponseCharacteristicUUID {
                // Replay recent JoinResponses to this newly-subscribed
                // central. They may have written their JoinRequest a
                // beat before subscribing, in which case our reply
                // was generated while their subscriber set was empty.
                // The joiner filters by inviteCode on receive, so
                // replaying a response for some other joiner is
                // harmless to them.
                guard let char = self.joinResponseCharacteristic,
                      self.peripheralManager.state == .poweredOn else { return }
                let cutoff = Date().addingTimeInterval(-Self.joinResponseReplayWindow)
                for entry in self.recentJoinResponses
                where entry.sentAt >= cutoff {
                    guard let data = entry.response.encoded() else { continue }
                    _ = self.peripheralManager.updateValue(
                        data,
                        for: char,
                        onSubscribedCentrals: [central]
                    )
                }
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        let charUUID = characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            if charUUID == Self.presenceCharacteristicUUID {
                self.currentDiagnostics.presenceSubscribers =
                    max(0, self.currentDiagnostics.presenceSubscribers - 1)
                self.emitDiagnostics()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        let charUUID = request.characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch charUUID {
            case Self.presenceCharacteristicUUID:
                self.serveBlobRead(request, on: peripheral, source: self.lastPresenceData)
            case Self.nearbyTokenCharacteristicUUID:
                self.serveBlobRead(request, on: peripheral, source: self.lastNearbyTokenData)
            default:
                peripheral.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }

    /// Serve a (possibly large) dynamic characteristic value across a
    /// multi-PDU Read Blob sequence. TWO things are required for a value
    /// bigger than the ATT MTU:
    ///   1. Slice from `request.offset`, not the whole buffer.
    ///   2. Keep the buffer byte-for-byte STABLE for the whole sequence.
    ///      Presence is re-broadcast constantly (heartbeat + 10 Hz seek
    ///      ramp); serving the live buffer per-blob let the central splice
    ///      chunks from DIFFERENT versions → corrupt reassembly → decode
    ///      failed every time (the bug that starved capability + UWB
    ///      token). So we freeze a per-central snapshot at offset 0 and
    ///      serve later blobs from it.
    /// Note: a characteristic value still can't exceed the 512-byte ATT
    /// ceiling — values larger than that simply can't be read, which is
    /// why the big UWB token has its own characteristic and presence was
    /// slimmed below 512.
    private func serveBlobRead(_ request: CBATTRequest,
                               on peripheral: CBPeripheralManager,
                               source: Data?) {
        let key = request.central.identifier.uuidString + ":"
            + request.characteristic.uuid.uuidString
        let snapshot: Data
        if request.offset == 0 {
            snapshot = source ?? Data()
            readSnapshots[key] = snapshot
        } else {
            snapshot = readSnapshots[key] ?? source ?? Data()
        }
        guard request.offset <= snapshot.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = snapshot.subdata(in: request.offset ..< snapshot.count)
        peripheral.respond(to: request, withResult: .success)
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveWrite requests: [CBATTRequest]) {
        // Decode every JoinRequest in the batch; AppState validates
        // each one (invite-code match, banlist). ATT requires us to
        // respond exactly once for the whole batch, so we collect
        // all results and use the first request as the response
        // anchor — same convention CoreBluetooth's own sample code
        // recommends for write batches.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for request in requests {
                guard let data = request.value else { continue }
                switch request.characteristic.uuid {
                case Self.joinRequestCharacteristicUUID:
                    if let joinRequest = JoinRequest.decoded(from: data) {
                        self.incomingJoinRequestContinuation.yield(joinRequest)
                    }
                case Self.seekingSignalCharacteristicUUID:
                    if let signal = SeekingSignal.decoded(from: data) {
                        self.incomingSeekingSignalContinuation.yield(signal)
                    }
                default:
                    break
                }
            }
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .success)
            }
        }
    }
}

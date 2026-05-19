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

@MainActor
protocol BLEPresenceServicing: AnyObject {
    var peerUpdates: AsyncStream<PeerPresence> { get }
    var rssiUpdates: AsyncStream<RSSIReading> { get }

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

    /// Stream of diagnostics about the BLE pipe.
    var diagnostics: AsyncStream<BLEDiagnostics> { get }

    func start(groupHash: UInt32, localPresence: PeerPresence)
    func update(localPresence: PeerPresence)
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
    let joinResponses: AsyncStream<JoinResponse>
    let incomingJoinRequests: AsyncStream<JoinRequest>
    let diagnostics: AsyncStream<BLEDiagnostics>
    private nonisolated let peerContinuation: AsyncStream<PeerPresence>.Continuation
    private nonisolated let rssiContinuation: AsyncStream<RSSIReading>.Continuation
    private nonisolated let joinResponseContinuation: AsyncStream<JoinResponse>.Continuation
    private nonisolated let incomingJoinRequestContinuation: AsyncStream<JoinRequest>.Continuation
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

    /// Maps CB peripheral identifier → group member UUID. Populated once
    /// we've successfully read a peer's presence characteristic, which
    /// tells us who they are. Lets us tag subsequent RSSI scan callbacks.
    private var peripheralToMember: [UUID: UUID] = [:]

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

    /// Last time we yielded a diagnostics snapshot driven by an RSSI
    /// sample. RSSI callbacks fire many times per second; without this
    /// throttle the diagnostics stream would dominate the run loop.
    private var lastRSSIDiagnosticsEmit: Date = .distantPast
    private static let rssiDiagnosticsMinInterval: TimeInterval = 0.5

    // MARK: - Init

    override init() {
        let (peerStream, peerCont) = AsyncStream.makeStream(of: PeerPresence.self)
        let (rssiStream, rssiCont) = AsyncStream.makeStream(of: RSSIReading.self)
        let (joinStream, joinCont) = AsyncStream.makeStream(of: JoinResponse.self)
        let (joinReqStream, joinReqCont) = AsyncStream.makeStream(of: JoinRequest.self)
        let (diagStream, diagCont) = AsyncStream.makeStream(of: BLEDiagnostics.self)
        self.peerUpdates = peerStream
        self.rssiUpdates = rssiStream
        self.joinResponses = joinStream
        self.incomingJoinRequests = joinReqStream
        self.diagnostics = diagStream
        self.peerContinuation = peerCont
        self.rssiContinuation = rssiCont
        self.joinResponseContinuation = joinCont
        self.incomingJoinRequestContinuation = joinReqCont
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
        pendingJoinRequest = nil
        beginScanIfReady()
        beginAdvertisingIfReady()
    }

    func update(localPresence: PeerPresence) {
        guard let data = localPresence.encoded() else { return }
        lastPresenceData = data
        if let char = presenceCharacteristic {
            // Push to all subscribed centrals via BLE notify — fast path
            // (sub-second to peers with a live connection).
            peripheralManager.updateValue(
                data,
                for: char,
                onSubscribedCentrals: nil
            )
        }
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
        connectTimestamps.removeAll()
        presenceRetryTask?.cancel()
        presenceRetryTask = nil
        discoveredPeripherals.removeAll()
        servicesDiscoveredFor.removeAll()
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
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
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
        let svc = CBMutableService(type: Self.serviceUUID, primary: true)
        svc.characteristics = [presence, joinReqChar, joinRespChar]
        peripheralManager.add(svc)
        presenceCharacteristic = presence
        joinRequestCharacteristic = joinReqChar
        joinResponseCharacteristic = joinRespChar
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
        // updateValue to all subscribed centrals — the joiner
        // filters by invite code on receive. We don't have a clean
        // way to target a specific central without tracking the
        // CBCentral object across the write→respond roundtrip, and
        // the broadcast is harmless to non-matching listeners.
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
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

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
        // Don't remove the peripheral→member mapping here; we want to
        // keep emitting RSSI for that member if their iBeacon advert is
        // still detectable while we wait for a fresh GATT reconnect.
    }

    private func handlePresenceData(_ data: Data, from peripheral: CBPeripheral) {
        guard let presence = PeerPresence.decoded(from: data) else { return }
        // Active-group filter: drop connections to peers from other
        // groups. Skipped during join-discovery — we don't have an
        // activeGroupHash but we need to stay connected long enough
        // for the JoinResponse to arrive; the joinRequest write
        // already filters by invite-code match server-side.
        let isDiscoveryMode = activeGroupHash == nil && pendingJoinRequest != nil
        guard isDiscoveryMode || presence.groupHash == activeGroupHash else {
            // Different group — drop the connection so we don't keep a
            // pointless link open.
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
        currentDiagnostics.mappedMemberCount = peripheralToMember.count
        emitDiagnostics()
        peerContinuation.yield(presence)
    }

    /// Decode an incoming JoinResponse off the wire and surface it
    /// to AppState via the stream. Called when a remote peripheral
    /// notifies us on the joinResponse characteristic during
    /// discovery mode.
    private func handleJoinResponseData(_ data: Data) {
        guard let response = JoinResponse.decoded(from: data) else { return }
        // Sanity: only yield responses that match the invite code we
        // asked for. Discards crossed-wire responses if multiple
        // join attempts are in flight (shouldn't happen given we
        // single-thread join through `pendingJoinRequest`, but
        // defense in depth).
        guard let request = pendingJoinRequest,
              response.inviteCode == request.inviteCode else { return }
        joinResponseContinuation.yield(response)
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
            guard peripheralToMember[id] == nil else { continue }
            guard let since = connectTimestamps[id],
                  now.timeIntervalSince(since) >= Self.presenceReadRetryDelay
            else { continue }
            // Reset the timestamp so we only retry once per window.
            connectTimestamps[id] = now

            // Two possible failure modes, both recoverable:
            //
            // 1. Service discovery never completed (didDiscoverServices
            //    silently stalled — happens with stale GATT cache, or
            //    when the link was up before encryption finished).
            //    Symptom: peripheral.services is nil/empty.
            //    Recovery: re-issue discoverServices.
            //
            // 2. Discovery completed but the initial read returned no
            //    data or decode failed. Symptom: we have the
            //    characteristic but no member mapping.
            //    Recovery: re-issue readValue.
            let service = peripheral.services?.first { $0.uuid == Self.serviceUUID }
            let char = service?.characteristics?.first {
                $0.uuid == Self.presenceCharacteristicUUID
            }
            if let char {
                peripheral.readValue(for: char)
            } else {
                peripheral.delegate = self
                peripheral.discoverServices([Self.serviceUUID])
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
                     Self.joinResponseCharacteristicUUID],
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
            for char in chars {
                switch char.uuid {
                case Self.presenceCharacteristicUUID:
                    // 1. Initial read so we get the peer's current state right away.
                    peripheral.readValue(for: char)
                    // 2. Subscribe for ongoing live updates pushed via notify.
                    peripheral.setNotifyValue(true, for: char)
                case Self.joinResponseCharacteristicUUID:
                    // Join discovery — subscribe so a peer's reply
                    // notifies us. Only relevant when we're in
                    // discovery mode; harmless otherwise.
                    peripheral.setNotifyValue(true, for: char)
                case Self.joinRequestCharacteristicUUID:
                    // If we're currently looking to join, write the
                    // request to this peer right now. Discovery
                    // mode bypasses the activeGroupHash filter so
                    // every peer we reach gets a chance to answer.
                    self.writeJoinRequestIfPossible(to: peripheral)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let charUUID = characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch charUUID {
            case Self.presenceCharacteristicUUID:
                self.handlePresenceData(data, from: peripheral)
            case Self.joinResponseCharacteristicUUID:
                self.handleJoinResponseData(data)
            default:
                break
            }
        }
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
                   let char = self.presenceCharacteristic {
                    self.peripheralManager.updateValue(
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
                // Always respond with success — `attributeNotFound`
                // leaves the central in a strange state where the
                // characteristic exists but is "unreadable", and
                // CoreBluetooth doesn't surface that cleanly to our
                // delegate. An empty `Data()` decodes to nil presence
                // on the central, which the retry watchdog handles
                // by re-issuing the read once we have fresh data.
                request.value = self.lastPresenceData ?? Data()
                peripheral.respond(to: request, withResult: .success)
            default:
                peripheral.respond(to: request, withResult: .attributeNotFound)
            }
        }
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
            for request in requests
            where request.characteristic.uuid == Self.joinRequestCharacteristicUUID {
                if let data = request.value,
                   let joinRequest = JoinRequest.decoded(from: data) {
                    self.incomingJoinRequestContinuation.yield(joinRequest)
                }
            }
            if let first = requests.first {
                peripheral.respond(to: first, withResult: .success)
            }
        }
    }
}

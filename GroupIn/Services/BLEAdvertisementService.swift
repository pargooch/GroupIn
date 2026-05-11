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
    /// Incoming chat messages from in-range peers. Filtered by group
    /// hash; only messages matching the active group's hash arrive.
    var chatMessages: AsyncStream<ChatMessage> { get }

    /// Incoming `Event` payloads from in-range peers — the BLE-side
    /// of the event log gossip. AppState applies them through the
    /// reducer just like CloudKit-fetched events. Filtering by group
    /// happens at the consumer (events carry their own groupID, and
    /// only one group at a time is "active" for BLE advertising).
    var events: AsyncStream<Event> { get }

    /// Stream of diagnostics about the peripheral side of the BLE pipe:
    /// how many remote centrals are connected to us, how many have
    /// subscribed to chat. Useful for surfacing "no one's listening"
    /// states in the UI.
    var diagnostics: AsyncStream<BLEDiagnostics> { get }

    func start(groupHash: UInt32, localPresence: PeerPresence)
    func update(localPresence: PeerPresence)
    func stop()
    /// Push a chat message to all subscribed central peers.
    func send(chatMessage: ChatMessage)

    /// Broadcast a single event over the events characteristic.
    /// Caller is responsible for cursor-based gating (deciding
    /// whether anyone in range needs it) and for calling
    /// `Event.strippedForBLE()` if the payload has large blobs.
    func broadcastEvent(_ event: Event)
}

struct BLEDiagnostics: Sendable, Equatable {
    var chatSubscribers: Int
    var presenceSubscribers: Int
    var serviceAddFailed: Bool
    /// True when both BLE roles report `.poweredOn`. Optimistic at app
    /// launch so we don't flash a "Bluetooth is off" banner before iOS
    /// has reported the real state. Driven down to false the moment
    /// either manager sees `.poweredOff` / `.unauthorized` / `.unsupported`.
    var bluetoothReady: Bool = true
}

@MainActor
final class BLEAdvertisementService: NSObject, BLEPresenceServicing {

    // MARK: - GATT identifiers

    /// Service UUID — distinguishes GroupIn from any other BLE peripheral.
    /// Centrals filter scans on this so we don't see every random AirPod.
    static let serviceUUID = CBUUID(string: "A5B7E1C0-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Characteristic UUID for the JSON-encoded PeerPresence payload.
    static let presenceCharacteristicUUID = CBUUID(string: "A5B7E1C1-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Characteristic UUID for the JSON-encoded ChatMessage payload.
    /// Same notify-on-write pattern as presence, just a different payload
    /// shape; we share the same GroupIn service.
    static let chatCharacteristicUUID = CBUUID(string: "A5B7E1C2-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Characteristic UUID for JSON-encoded `Event` payloads — the
    /// peer-to-peer gossip channel for the unified event log. Same
    /// read+notify pattern as presence/chat; receivers fold incoming
    /// events through the reducer and dedup via their own cursor.
    static let eventsCharacteristicUUID = CBUUID(string: "A5B7E1C3-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// iBeacon UUID for region monitoring. Different from the BLE service
    /// UUID because iBeacon advertisements use a manufacturer-data format
    /// while BLE service advertisements use the service-UUID list — iOS
    /// only lets us advertise one mode at a time, so the peripheral
    /// alternates between the two below.
    static let iBeaconUUID = UUID(uuidString: "1A7B5F30-9E2C-4D3B-8A5F-2C9D7E1A4F5B")!

    // MARK: - Streams

    let peerUpdates: AsyncStream<PeerPresence>
    let rssiUpdates: AsyncStream<RSSIReading>
    let chatMessages: AsyncStream<ChatMessage>
    let events: AsyncStream<Event>
    let diagnostics: AsyncStream<BLEDiagnostics>
    private nonisolated let peerContinuation: AsyncStream<PeerPresence>.Continuation
    private nonisolated let rssiContinuation: AsyncStream<RSSIReading>.Continuation
    private nonisolated let chatContinuation: AsyncStream<ChatMessage>.Continuation
    private nonisolated let eventContinuation: AsyncStream<Event>.Continuation
    private nonisolated let diagnosticsContinuation: AsyncStream<BLEDiagnostics>.Continuation

    private var currentDiagnostics = BLEDiagnostics(
        chatSubscribers: 0,
        presenceSubscribers: 0,
        serviceAddFailed: false,
        bluetoothReady: true
    )

    // MARK: - Stack

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    private var presenceCharacteristic: CBMutableCharacteristic?
    private var chatCharacteristic: CBMutableCharacteristic?
    private var eventsCharacteristic: CBMutableCharacteristic?
    private var advertisedService: CBMutableService?
    private var serviceAdded: Bool = false
    private var lastChatData: Data?
    /// Most recently broadcast event payload, exposed so a central
    /// connecting later can read the latest single event we have. The
    /// event log on CloudKit + the cursor-mismatch push are how peers
    /// catch up on history; this just keeps the BLE characteristic
    /// from looking empty on initial read.
    private var lastEventData: Data?

    /// Outbox for event-batch updates that hit a full BLE transmission
    /// queue. Same pattern as `pendingChatUpdates`.
    private var pendingEventUpdates: [Data] = []

    /// Outbox for chat updates that hit a full BLE transmission queue.
    /// `peripheralManager.updateValue` returns false when iOS can't
    /// accept right now; we retry from `peripheralManagerIsReady(...)`.
    /// Without this, fast-typed messages or congested channels silently
    /// drop messages.
    private var pendingChatUpdates: [Data] = []

    private var activeGroupHash: UInt32?
    private var localMemberID: UUID?
    private var lastPresenceData: Data?

    /// Toggles the peripheral's advertised packet between Phase-1 GATT
    /// discovery (service UUID) and Phase-3 region wake (iBeacon).
    private var advertisingTask: Task<Void, Never>?
    private static let advertiseToggleInterval: TimeInterval = 4

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

    // MARK: - Init

    override init() {
        let (peerStream, peerCont) = AsyncStream.makeStream(of: PeerPresence.self)
        let (rssiStream, rssiCont) = AsyncStream.makeStream(of: RSSIReading.self)
        let (chatStream, chatCont) = AsyncStream.makeStream(of: ChatMessage.self)
        let (eventStream, eventCont) = AsyncStream.makeStream(of: Event.self)
        let (diagStream, diagCont) = AsyncStream.makeStream(of: BLEDiagnostics.self)
        self.peerUpdates = peerStream
        self.rssiUpdates = rssiStream
        self.chatMessages = chatStream
        self.events = eventStream
        self.diagnostics = diagStream
        self.peerContinuation = peerCont
        self.rssiContinuation = rssiCont
        self.chatContinuation = chatCont
        self.eventContinuation = eventCont
        self.diagnosticsContinuation = diagCont
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
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
        chatCharacteristic = nil
        eventsCharacteristic = nil
        lastEventData = nil
        pendingEventUpdates.removeAll()
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
        pendingChatUpdates.removeAll()
        lastChatData = nil
        activeGroupHash = nil
        localMemberID = nil
        currentDiagnostics = BLEDiagnostics(
            chatSubscribers: 0,
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
        guard centralManager.state == .poweredOn,
              activeGroupHash != nil else { return }
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
        startAlternatingAdvertisement()
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
        let chat = CBMutableCharacteristic(
            type: Self.chatCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let eventsChar = CBMutableCharacteristic(
            type: Self.eventsCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let svc = CBMutableService(type: Self.serviceUUID, primary: true)
        svc.characteristics = [presence, chat, eventsChar]
        peripheralManager.add(svc)
        presenceCharacteristic = presence
        chatCharacteristic = chat
        eventsCharacteristic = eventsChar
        advertisedService = svc
        serviceAdded = true
    }

    func send(chatMessage: ChatMessage) {
        guard let data = chatMessage.encoded() else { return }
        lastChatData = data
        pendingChatUpdates.append(data)
        drainChatQueue()
    }

    /// Broadcast a single Event to all subscribed centrals over the
    /// events characteristic. Caller is responsible for cursor-based
    /// filtering (deciding whether anyone needs it) and for stripping
    /// oversized fields (avatarData) via `Event.strippedForBLE()`.
    ///
    /// Per-event encoding (not batched) keeps payload size predictable
    /// and avoids the BLE MTU fragmentation problem entirely for the
    /// shapes we currently emit. If a future event type grows beyond
    /// ~150 encoded bytes, we'll need real fragmentation here.
    func broadcastEvent(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        lastEventData = data
        pendingEventUpdates.append(data)
        drainEventQueue()
    }

    /// Drain pending chat updates through `peripheralManager.updateValue`.
    /// Returns early if iOS pushes back; the manager will call
    /// `peripheralManagerIsReady(toUpdateSubscribers:)` once it can
    /// accept more, and we resume from there.
    private func drainChatQueue() {
        guard let char = chatCharacteristic else { return }
        while let next = pendingChatUpdates.first {
            let delivered = peripheralManager.updateValue(
                next,
                for: char,
                onSubscribedCentrals: nil
            )
            if delivered {
                pendingChatUpdates.removeFirst()
            } else {
                return
            }
        }
    }

    /// Same drain pattern as chat — push queued events through
    /// `updateValue`, stop on backpressure. Resumed from
    /// `peripheralManagerIsReady` when iOS has room again.
    private func drainEventQueue() {
        guard let char = eventsCharacteristic else { return }
        while let next = pendingEventUpdates.first {
            let delivered = peripheralManager.updateValue(
                next,
                for: char,
                onSubscribedCentrals: nil
            )
            if delivered {
                pendingEventUpdates.removeFirst()
            } else {
                return
            }
        }
    }

    private func considerConnect(to peripheral: CBPeripheral) {
        guard activeGroupHash != nil else { return }
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
        // Don't remove the peripheral→member mapping here; we want to
        // keep emitting RSSI for that member if their iBeacon advert is
        // still detectable while we wait for a fresh GATT reconnect.
    }

    private func handlePresenceData(_ data: Data, from peripheral: CBPeripheral) {
        guard let presence = PeerPresence.decoded(from: data) else { return }
        guard presence.groupHash == activeGroupHash else {
            // Different group — drop the connection so we don't keep a
            // pointless link open.
            centralManager.cancelPeripheralConnection(peripheral)
            peripheralToMember.removeValue(forKey: peripheral.identifier)
            return
        }
        // Now that we know which member this peripheral is, tag future
        // scan callbacks with their member ID for the RSSI stream.
        peripheralToMember[peripheral.identifier] = presence.memberID
        peerContinuation.yield(presence)
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

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let rssiValue = RSSI.doubleValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Emit an RSSI sample if we already know which member this
            // peripheral belongs to. The compass uses these for gradient
            // bearing computation when GPS isn't viable.
            if let memberID = self.peripheralToMember[peripheral.identifier] {
                self.rssiContinuation.yield(RSSIReading(
                    memberID: memberID,
                    rssi: rssiValue,
                    timestamp: .now
                ))
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
            peripheral.discoverServices([Self.serviceUUID])
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
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == Self.serviceUUID {
                // Discover BOTH characteristics. The previous single-
                // entry filter silently dropped chat — sender pushed
                // notifies fine, but no peer ever subscribed because
                // the chat characteristic was never discovered.
                peripheral.discoverCharacteristics(
                    [Self.presenceCharacteristicUUID,
                     Self.chatCharacteristicUUID,
                     Self.eventsCharacteristicUUID],
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
                case Self.chatCharacteristicUUID:
                    // Chat messages are notify-driven. No initial read —
                    // there's no concept of "current chat state," only a
                    // stream of new messages from this point onward.
                    peripheral.setNotifyValue(true, for: char)
                case Self.eventsCharacteristicUUID:
                    // Events: read once so we pick up the most-recent
                    // event the peer last broadcast (which is what's
                    // sitting in their characteristic's last value),
                    // then subscribe for the rest pushed via notify.
                    // The cursor-mismatch push from AppState fills in
                    // any older missing events too.
                    peripheral.readValue(for: char)
                    peripheral.setNotifyValue(true, for: char)
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
            case Self.chatCharacteristicUUID:
                self.handleChatData(data)
            case Self.eventsCharacteristicUUID:
                self.handleEventData(data)
            default:
                break
            }
        }
    }

    private func handleEventData(_ data: Data) {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
            return
        }
        // Yield the event up to AppState's gossip consumer. Dedup
        // happens there — comparing against the local event log so
        // already-seen events don't re-trigger reducer application
        // or onward gossip.
        eventContinuation.yield(event)
    }

    private func handleChatData(_ data: Data) {
        guard let message = ChatMessage.decoded(from: data) else { return }
        // Drop messages from a different group; the per-device chat
        // characteristic broadcasts to all subscribers regardless of
        // group, so we filter at the app layer.
        guard message.groupHash == activeGroupHash else { return }
        chatContinuation.yield(message)
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

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // The transmission queue has space again. Resume any chat
        // messages and event broadcasts we couldn't push earlier.
        Task { @MainActor [weak self] in
            self?.drainChatQueue()
            self?.drainEventQueue()
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
            switch charUUID {
            case Self.chatCharacteristicUUID:
                self.currentDiagnostics.chatSubscribers += 1
            case Self.presenceCharacteristicUUID:
                self.currentDiagnostics.presenceSubscribers += 1
            default:
                break
            }
            self.emitDiagnostics()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        let charUUID = characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch charUUID {
            case Self.chatCharacteristicUUID:
                self.currentDiagnostics.chatSubscribers =
                    max(0, self.currentDiagnostics.chatSubscribers - 1)
            case Self.presenceCharacteristicUUID:
                self.currentDiagnostics.presenceSubscribers =
                    max(0, self.currentDiagnostics.presenceSubscribers - 1)
            default:
                break
            }
            self.emitDiagnostics()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        let charUUID = request.characteristic.uuid
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch charUUID {
            case Self.presenceCharacteristicUUID:
                if let data = self.lastPresenceData {
                    request.value = data
                    peripheral.respond(to: request, withResult: .success)
                } else {
                    peripheral.respond(to: request, withResult: .attributeNotFound)
                }
            case Self.chatCharacteristicUUID:
                if let data = self.lastChatData {
                    request.value = data
                    peripheral.respond(to: request, withResult: .success)
                } else {
                    // No message sent yet — respond cleanly with empty
                    // value rather than an error.
                    request.value = Data()
                    peripheral.respond(to: request, withResult: .success)
                }
            case Self.eventsCharacteristicUUID:
                // Hand back the most recently broadcast event so a
                // central connecting mid-stream gets *something* on
                // initial read. The full catch-up flows through the
                // cursor-mismatch push from AppState — there's no
                // notion of "the current event," only "the latest
                // event we happen to have broadcast."
                request.value = self.lastEventData ?? Data()
                peripheral.respond(to: request, withResult: .success)
            default:
                peripheral.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }
}

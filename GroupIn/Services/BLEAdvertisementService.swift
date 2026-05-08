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

@MainActor
protocol BLEPresenceServicing: AnyObject {
    var peerUpdates: AsyncStream<PeerPresence> { get }
    func start(groupHash: UInt32, localPresence: PeerPresence)
    func update(localPresence: PeerPresence)
    func stop()
}

@MainActor
final class BLEAdvertisementService: NSObject, BLEPresenceServicing {

    // MARK: - GATT identifiers

    /// Service UUID — distinguishes GroupIn from any other BLE peripheral.
    /// Centrals filter scans on this so we don't see every random AirPod.
    static let serviceUUID = CBUUID(string: "A5B7E1C0-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// Characteristic UUID for the JSON-encoded PeerPresence payload.
    static let presenceCharacteristicUUID = CBUUID(string: "A5B7E1C1-9F3D-4E2A-8B6F-1D7C5E9A4F8B")

    /// iBeacon UUID for region monitoring. Different from the BLE service
    /// UUID because iBeacon advertisements use a manufacturer-data format
    /// while BLE service advertisements use the service-UUID list — iOS
    /// only lets us advertise one mode at a time, so the peripheral
    /// alternates between the two below.
    static let iBeaconUUID = UUID(uuidString: "1A7B5F30-9E2C-4D3B-8A5F-2C9D7E1A4F5B")!

    // MARK: - Streams

    let peerUpdates: AsyncStream<PeerPresence>
    private nonisolated let peerContinuation: AsyncStream<PeerPresence>.Continuation

    // MARK: - Stack

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    private var presenceCharacteristic: CBMutableCharacteristic?
    private var advertisedService: CBMutableService?
    private var serviceAdded: Bool = false

    private var activeGroupHash: UInt32?
    private var lastPresenceData: Data?

    /// Toggles the peripheral's advertised packet between Phase-1 GATT
    /// discovery (service UUID) and Phase-3 region wake (iBeacon).
    private var advertisingTask: Task<Void, Never>?
    private static let advertiseToggleInterval: TimeInterval = 4

    /// Peripherals we've called `connect()` on but haven't yet seen
    /// `didConnect`. Keyed by `peripheral.identifier`.
    private var connectingPeers: Set<UUID> = []

    /// Peripherals with established connections we're keeping open.
    /// Strong reference holds them so iOS doesn't drop the link.
    private var connectedPeers: [UUID: CBPeripheral] = [:]

    // MARK: - Init

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: PeerPresence.self)
        self.peerUpdates = stream
        self.peerContinuation = continuation
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - Lifecycle

    func start(groupHash: UInt32, localPresence: PeerPresence) {
        activeGroupHash = groupHash
        update(localPresence: localPresence)
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
        activeGroupHash = nil
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
        // Pack the group hash into the iBeacon major+minor so other
        // GroupIn devices in the same group can theoretically tell each
        // other apart at the iBeacon layer if we want richer dedup later.
        let major = CLBeaconMajorValue((groupHash >> 16) & 0xFFFF)
        let minor = CLBeaconMinorValue(groupHash & 0xFFFF)
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

    private func setupService() {
        let char = CBMutableCharacteristic(
            type: Self.presenceCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,                  // dynamic value (required for read+notify)
            permissions: [.readable]
        )
        let svc = CBMutableService(type: Self.serviceUUID, primary: true)
        svc.characteristics = [char]
        peripheralManager.add(svc)
        presenceCharacteristic = char
        advertisedService = svc
        serviceAdded = true
    }

    private func considerConnect(to peripheral: CBPeripheral) {
        guard activeGroupHash != nil else { return }
        let id = peripheral.identifier
        if connectingPeers.contains(id) || connectedPeers[id] != nil { return }

        connectingPeers.insert(id)
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    private func cleanupPeer(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        connectingPeers.remove(id)
        connectedPeers.removeValue(forKey: id)
    }

    private func handlePresenceData(_ data: Data, from peripheral: CBPeripheral) {
        guard let presence = PeerPresence.decoded(from: data) else { return }
        guard presence.groupHash == activeGroupHash else {
            // Different group — drop the connection so we don't keep a
            // pointless link open.
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        peerContinuation.yield(presence)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEAdvertisementService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.beginScanIfReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            self?.considerConnect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = peripheral.identifier
            self.connectingPeers.remove(id)
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
                peripheral.discoverCharacteristics(
                    [Self.presenceCharacteristicUUID],
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
            for char in chars where char.uuid == Self.presenceCharacteristicUUID {
                // 1. Initial read so we get the peer's current state right away.
                peripheral.readValue(for: char)
                // 2. Subscribe for ongoing live updates pushed via notify.
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor [weak self] in
            self?.handlePresenceData(data, from: peripheral)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEAdvertisementService: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor [weak self] in
            self?.beginAdvertisingIfReady()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if request.characteristic.uuid == Self.presenceCharacteristicUUID,
               let data = self.lastPresenceData {
                request.value = data
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }
}

//
//  BLEAdvertisementService.swift
//  GroupIn
//
//  Foreground BLE peer presence over CoreBluetooth. Each device runs
//  *both* peripheral and central:
//
//    - As a peripheral: advertises a GroupIn service UUID and exposes one
//      characteristic carrying the local PeerPresence JSON.
//    - As a central: scans for the same service UUID, connects briefly to
//      each discovered peripheral, reads its presence characteristic,
//      disconnects.
//
//  Phase 1 scope: foreground only. iOS heavily restricts background BLE
//  for arbitrary apps; the strong-background story comes when paired to a
//  dedicated MagSafe accessory (see docs/MAGSAFE.md).
//

import Foundation
import CoreBluetooth

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

    /// Peripherals we're currently connected to (for one-shot reads).
    /// Held as a strong reference so iOS doesn't drop them mid-read.
    private var pendingReads: Set<CBPeripheral> = []

    /// Cooldown so we don't re-read the same peer every scan tick.
    /// Keyed by `peripheral.identifier` (CoreBluetooth's stable per-app
    /// peripheral ID — different from our membership UUID).
    private var lastReadAt: [UUID: Date] = [:]
    private let readCooldown: TimeInterval = 8

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
            char.value = data
            // Push to any subscribed centrals (none today, but harmless).
            peripheralManager.updateValue(
                data,
                for: char,
                onSubscribedCentrals: nil
            )
        }
    }

    func stop() {
        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }
        if peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
        }
        for peripheral in pendingReads {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        pendingReads.removeAll()
        lastReadAt.removeAll()
        activeGroupHash = nil
    }

    // MARK: - Internal

    private func beginScanIfReady() {
        guard centralManager.state == .poweredOn,
              activeGroupHash != nil else { return }
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func beginAdvertisingIfReady() {
        guard peripheralManager.state == .poweredOn,
              activeGroupHash != nil else { return }
        if !serviceAdded { setupService() }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
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

    private func considerRead(of peripheral: CBPeripheral) {
        // Already connecting / connected to this one — don't double-up.
        guard !pendingReads.contains(peripheral) else { return }

        // Cooldown so a duplicate-allowed scan doesn't hammer the link.
        if let last = lastReadAt[peripheral.identifier],
           Date().timeIntervalSince(last) < readCooldown {
            return
        }

        pendingReads.insert(peripheral)
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    private func handlePresenceData(_ data: Data, from peripheral: CBPeripheral) {
        defer {
            centralManager.cancelPeripheralConnection(peripheral)
            pendingReads.remove(peripheral)
            lastReadAt[peripheral.identifier] = .now
        }
        guard let presence = PeerPresence.decoded(from: data) else { return }
        guard presence.groupHash == activeGroupHash else { return }
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
            self?.considerRead(of: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            self?.pendingReads.remove(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor [weak self] in
            self?.pendingReads.remove(peripheral)
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
                peripheral.readValue(for: char)
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

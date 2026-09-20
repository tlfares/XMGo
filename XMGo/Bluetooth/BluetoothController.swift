@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class BluetoothController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStateChange: ((ConnectionState) -> Void)?
    var onDiscovery: ((DiscoveredHeadphone) -> Void)?
    var onConnected: ((String) -> Void)?
    var onControlAvailability: ((Bool, String?) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pendingReconnect = false
    // Sony BLG "Bluetooth Connection" (write) / "Bluetooth Connection Status"
    // (notify). Protocol-defined constants shared by every Sony unit, located by
    // discovery — never a per-unit identifier.
    private var bluetoothConnectionControl: CBCharacteristic?
    private var bluetoothConnectionPeripheral: CBPeripheral?
    private var rememberedIdentifier: UUID? {
        get {
            guard let value = UserDefaults.standard.string(forKey: "rememberedHeadphoneID") else { return nil }
            return UUID(uuidString: value)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "rememberedHeadphoneID") }
    }

    private var rememberedName: String? {
        UserDefaults.standard.string(forKey: "rememberedHeadphoneName")?
            .trimmingCharacters(in: .whitespaces)
    }

    /// True when the discovered peripheral is the headset we were last using,
    /// matched by identifier or by name (the name survives re-pairing, which
    /// mints a new identifier — Sound Connect reconnects by name this way).
    private func isRemembered(_ peripheral: CBPeripheral, name: String?) -> Bool {
        if peripheral.identifier == rememberedIdentifier { return true }
        guard let rememberedName, !rememberedName.isEmpty, let name else { return false }
        let normalize: (String) -> String = {
            $0.replacingOccurrences(of: "LE_", with: "")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        return normalize(name) == normalize(rememberedName)
    }

    /// Sony's 128-bit base UUID. Every Sony protocol-defined UUID shares this
    /// suffix, so it identifies "a Sony service/characteristic" on any model
    /// without hardcoding a single unit's identifier.
    private static let sonyBaseSuffix = "-6BC7-4802-8E9A-723CECA4BD8F"

    private func isSonyProtocol(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.uppercased().hasSuffix(Self.sonyBaseSuffix)
    }

    /// Short form for Sony protocol UUIDs (the 16-bit-like head), full form otherwise.
    private func shortUUID(_ uuid: CBUUID) -> String {
        let value = uuid.uuidString.uppercased()
        return isSonyProtocol(uuid) ? String(value.prefix(8)) : value
    }

    /// Peripherals iOS already has connected (by the system or another app),
/// without scanning. Sound Connect calls retrieveConnectedPeripherals for the
/// same reason: a dual-mode headset can be connected/known while it no longer
/// advertises, which makes a plain scan come up empty.
    private func systemConnectedRemembered() -> CBPeripheral? {
        let connected = central.retrieveConnectedPeripherals(withServices: [])
        print("[XMGo BLE] retrieveConnectedPeripherals -> \(connected.count)")
        return connected.first { isRemembered($0, name: $0.name) }
            ?? connected.first { peripheral in
                guard let name = peripheral.name else { return false }
                return Self.sonyLikeNames.contains { name.localizedCaseInsensitiveContains($0) }
            }
    }

    static let sonyLikeNames = ["WH-", "WF-", "WI-", "MDR-", "Sony"]

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func start() {
        pendingReconnect = true
        guard central.state == .poweredOn else { return }
        reconnectOrScan()
    }

    /// Requests the low-energy control link independently of the audio route.
    /// A WH-1000XM4 can reconnect A2DP after auto-off without restoring this
    /// link until a companion app explicitly asks CoreBluetooth to connect.
    func reconnectControlLink() {
        guard central.state == .poweredOn else { return }
        let peripheral = rememberedIdentifier.flatMap {
            central.retrievePeripherals(withIdentifiers: [$0]).first
        } ?? systemConnectedRemembered()
        guard let peripheral else {
            scan()
            return
        }
        rememberedIdentifier = peripheral.identifier
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        switch peripheral.state {
        case .disconnected:
            print("[XMGo BLE] requesting control link for \(peripheral.name ?? "?")")
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        case .connected:
            // The LE link is alive. Discovery never touches the EA overlay, so
            // do not cycle here — a full cancel+reconnect belongs to rebuildLink.
            peripheral.discoverServices(nil)
        case .connecting, .disconnecting:
            print("[XMGo BLE] link \(peripheral.name ?? "?") in state \(peripheral.state.rawValue) — waiting")
        @unknown default:
            break
        }
    }

    func scan() {
        guard central.state == .poweredOn else {
            onStateChange?(.unavailable("Turn on Bluetooth to search for your headset."))
            return
        }
        onStateChange?(.scanning)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Forces iOS to re-negotiate the device's link, which re-runs the iAP2
    /// identification that exposes the MFi control channel. iOS has no public
    /// API to attach it while a plain audio (A2DP) connection is alive, so the
    /// only programmatic lever is a cancel + reconnect of the remembered
    /// peripheral (the disconnect handler below re-connects immediately).
    func rebuildLink() {
        guard central.state == .poweredOn else { return }
        let peripheral = rememberedIdentifier.flatMap {
            central.retrievePeripherals(withIdentifiers: [$0]).first
        } ?? systemConnectedRemembered()
        guard let peripheral else {
            reconnectControlLink()
            return
        }
        rememberedIdentifier = peripheral.identifier
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        print("[XMGo BLE] rebuilding link for \(peripheral.name ?? "?") to re-expose the control channel")
        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        } else {
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        }
    }

    /// True once the Sony BLG "Bluetooth Connection" characteristic is in range.
    var canCommandBluetoothConnection: Bool { bluetoothConnectionControl != nil }

    /// Writes a raw value to Sony's BLG "Bluetooth Connection" characteristic.
    ///
    /// This is the exact channel Sound Connect uses to tell the headset to bring
    /// its Bluetooth Classic (SPP/iAP) link back up, which is what makes iOS
    /// re-expose the MFi control accessory. The payload is a 6-byte BD address,
    /// so it is only sent when the caller knows the target address.
    @discardableResult
    func writeBluetoothConnection(_ bytes: [UInt8]) -> Bool {
        guard let peripheral = bluetoothConnectionPeripheral,
              let characteristic = bluetoothConnectionControl,
              peripheral.state == .connected else { return false }
        let value = Data(bytes)
        peripheral.writeValue(value, for: characteristic, type: .withResponse)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        print("[XMGo BLE] BluetoothConnection <- \(hex)")
        return true
    }

    func stopScan() {
        central.stopScan()
        onStateChange?(.idle)
    }

    func connect(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.stopScan()
        onStateChange?(.connecting)
        central.connect(peripheral, options: nil)
    }

    private func reconnectOrScan() {
        let peripheral = rememberedIdentifier.flatMap {
            central.retrievePeripherals(withIdentifiers: [$0]).first
        } ?? systemConnectedRemembered()
        if let peripheral {
            rememberedIdentifier = peripheral.identifier
            peripherals[peripheral.identifier] = peripheral
            onDiscovery?(.init(id: peripheral.identifier,
                               name: peripheral.name ?? UserDefaults.standard.string(forKey: "rememberedHeadphoneName") ?? "Sony headset",
                               signal: Int.min))
            onStateChange?(.connecting)
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        } else {
            scan()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[XMGo BLE] central state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn where pendingReconnect:
            pendingReconnect = false
            reconnectOrScan()
        case .poweredOff: onStateChange?(.unavailable("Bluetooth is off."))
        case .unauthorized: onStateChange?(.unavailable("Allow Bluetooth in Settings."))
        case .unsupported: onStateChange?(.unavailable("Bluetooth is not available on this device."))
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? "Bluetooth device"
        guard name.localizedCaseInsensitiveContains("Sony") ||
                name.localizedCaseInsensitiveContains("WH-") ||
                name.localizedCaseInsensitiveContains("WF-") else { return }
        peripherals[peripheral.identifier] = peripheral
        print("[XMGo BLE] discovered \(name), id=\(peripheral.identifier), state=\(peripheral.state.rawValue)")
        onDiscovery?(.init(id: peripheral.identifier, name: name, signal: RSSI.intValue))

        if isRemembered(peripheral, name: name), peripheral.state == .disconnected {
            central.stopScan()
            onStateChange?(.connecting)
            rememberedIdentifier = peripheral.identifier
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[XMGo BLE] connected \(peripheral.name ?? "?")")
        peripheral.delegate = self
        rememberedIdentifier = peripheral.identifier
        UserDefaults.standard.set(peripheral.name ?? "Sony headset", forKey: "rememberedHeadphoneName")
        onStateChange?(.connected)
        onConnected?(peripheral.name ?? "Sony headset")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            onControlAvailability?(false, error?.localizedDescription)
            return
        }
        let services = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "none"
        print("[XMGo BLE] services for \(peripheral.name ?? "?"): \(services)")
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("bcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeNR") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authWrite") }
        if properties.contains(.extendedProperties) { names.append("ext") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            print("[XMGo BLE] service \(service.uuid.uuidString): no characteristics error=\(error?.localizedDescription ?? "none")")
            return
        }
        let detail = characteristics.map { "\(shortUUID($0.uuid))[\(propertyNames($0.properties))]" }
        print("[XMGo BLE] service \(service.uuid.uuidString): \(detail.joined(separator: ", "))")
        for characteristic in characteristics where
            characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
            // 5B833C10 = Sony BLG "Bluetooth Connection" (classic link control).
            if shortUUID(characteristic.uuid) == "5B833C10" {
                bluetoothConnectionControl = characteristic
                bluetoothConnectionPeripheral = peripheral
            }
        }
        // Keep the notify/direct channels open so the headset can live-push its
        // variable state without the app having to poll.
        for characteristic in characteristics
        where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("[XMGo BLE] write \(shortUUID(characteristic.uuid)) error=\(error?.localizedDescription ?? "none")")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[XMGo BLE] failed \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "none")")
        onStateChange?(.unavailable(error?.localizedDescription ?? "Connection failed."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        print("[XMGo BLE] disconnected \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "none")")
        onStateChange?(.idle)
        // Keep iOS' reconnection request alive through the headset's auto-off
        // and subsequent audio reconnect, just as Sound Connect does.
        if peripheral.identifier == rememberedIdentifier {
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            ])
        }
    }
}

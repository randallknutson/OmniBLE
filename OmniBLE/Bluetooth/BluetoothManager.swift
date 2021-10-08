//
//  BluetoothManager.swift
//  OmniBLE
//
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import CoreBluetooth
import os.log
import LoopKit

let advertisedServiceUUID = CBUUID(string: "00004024-0000-1000-8000-00805f9b34fb")

public class BluetoothManager: NSObject {
    private let log = OSLog(category: "BluetoothManager")

    // Isolated to centralQueue
    private var central: CBCentralManager!

    private let centralQueue = DispatchQueue(label: "com.omnikit.OmniKit.BluetoothManager.centralQueue", qos: .unspecified)

    internal let sessionQueue = DispatchQueue(label: "com.omnikit.OmniKit.BluetoothManager.sessionQueue", qos: .unspecified)

    // Isolated to centralQueue
    private var devices: [OmniBLEDevice] = [] {
        didSet {
            NotificationCenter.default.post(name: .ManagerDevicesDidChange, object: self)
        }
    }

    // Isolated to centralQueue
    private var autoConnectIDs: Set<String>

    // Isolated to centralQueue
    private var isScanningEnabled = false

    public init(autoConnectIDs: Set<String>) {
        self.autoConnectIDs = autoConnectIDs

        super.init()

        centralQueue.sync {
            central = CBCentralManager(
                delegate: self,
                queue: centralQueue,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: "com.omnible.CentralManager"
                ]
            )
        }
    }
    
    public func firstConnectedDevice(_ completion: @escaping (_ device: OmniBLEDevice?) -> Void) {
        getDevices { (devices) in
            completion(devices.firstConnected)
        }
    }

    // MARK: - Configuration

    public var idleListeningEnabled: Bool {
        if case .disabled = idleListeningState {
            return false
        } else {
            return true
        }
    }

    public var idleListeningState: OmniBLEDevice.IdleListeningState {
        get {
            return lockedIdleListeningState.value
        }
        set {
            lockedIdleListeningState.value = newValue
            centralQueue.async {
                for device in self.devices {
                    device.setIdleListeningState(newValue)
                }
            }
        }
    }
    private let lockedIdleListeningState = Locked(OmniBLEDevice.IdleListeningState.disabled)

    public var timerTickEnabled: Bool {
        get {
            return lockedTimerTickEnabled.value
        }
        set {
            lockedTimerTickEnabled.value = newValue
            centralQueue.async {
                for device in self.devices {
                    if device.peripheralState == .connected {
                        device.setTimerTickEnabled(newValue)
                    }
                }
            }
        }
    }
    private let lockedTimerTickEnabled = Locked(true)
}


// MARK: - Connecting
extension BluetoothManager {
    public func getAutoConnectIDs(_ completion: @escaping (_ autoConnectIDs: Set<String>) -> Void) {
        centralQueue.async {
            completion(self.autoConnectIDs)
        }
    }
    
    public func connect(_ device: OmniBLEDevice) {
        centralQueue.async {
            self.autoConnectIDs.insert(device.manager.peripheral.identifier.uuidString)

            guard let peripheral = self.reloadPeripheral(for: device) else {
                return
            }

            self.central.connectIfNecessary(peripheral)
        }
    }

    public func disconnect(_ device: OmniBLEDevice) {
        centralQueue.async {
            self.autoConnectIDs.remove(device.manager.peripheral.identifier.uuidString)

            guard let peripheral = self.reloadPeripheral(for: device) else {
                return
            }

            self.central.cancelPeripheralConnectionIfNecessary(peripheral)
        }
    }

    /// Asks the central manager for its peripheral instance for a given device.
    /// It seems to be possible that this reference changes across a bluetooth reset, and not updating the reference can result in API MISUSE warnings
    ///
    /// - Parameter device: The device to reload
    /// - Returns: The peripheral instance returned by the central manager
    private func reloadPeripheral(for device: OmniBLEDevice) -> CBPeripheral? {
        dispatchPrecondition(condition: .onQueue(centralQueue))

        guard let peripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first else {
            return nil
        }

        device.manager.peripheral = peripheral
        return peripheral
    }

    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(centralQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    private func autoConnectDevices() {
        dispatchPrecondition(condition: .onQueue(centralQueue))

        for device in devices where autoConnectIDs.contains(device.manager.peripheral.identifier.uuidString) {
            log.info("Attempting reconnect to %@", device.manager.peripheral)
            connect(device)
        }
    }

    private func addPeripheral(_ peripheral: CBPeripheral, _ advertisementData: [String: Any]?) {
        dispatchPrecondition(condition: .onQueue(centralQueue))

        var device: OmniBLEDevice! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            device.manager.peripheral = peripheral
        } else {
            device = OmniBLEDevice(peripheralManager: PeripheralManager(peripheral: peripheral, centralManager: central, queue: sessionQueue), advertisementData: advertisementData)
            if peripheral.state == .connected {
                device.setTimerTickEnabled(timerTickEnabled)
                device.setIdleListeningState(idleListeningState)
            }

            devices.append(device)

            log.info("Created device for peripheral %@", peripheral)
        }

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            central.connectIfNecessary(peripheral)
        }
    }
}


extension BluetoothManager {
    public func getDevices(_ completion: @escaping (_ devices: [OmniBLEDevice]) -> Void) {
        centralQueue.async {
            completion(self.devices)
        }
    }

    public func deprioritize(_ device: OmniBLEDevice, completion: (() -> Void)? = nil) {
        centralQueue.async {
            self.devices.deprioritize(device)
            completion?()
        }
    }
}

extension Array where Element == OmniBLEDevice {
    public var firstConnected: Element? {
        return self.first { (device) -> Bool in
            return device.manager.peripheral.state == .connected
        }
    }

    mutating func deprioritize(_ element: Element) {
        if let index = self.firstIndex(where: { $0 === element }) {
            self.swapAt(index, self.count - 1)
        }
    }
}


// MARK: - Scanning
extension BluetoothManager {
    public func setScanningEnabled(_ enabled: Bool) {
        centralQueue.async {
            self.isScanningEnabled = enabled

            if case .poweredOn = self.central.state {
                if enabled {
                    self.central.scanForPeripherals()
                } else if self.central.isScanning {
                    self.central.stopScan()
                }
            }
        }
    }

    public func assertIdleListening(forcingRestart: Bool) {
        centralQueue.async {
            for device in self.devices {
                device.assertIdleListening(forceRestart: forcingRestart)
            }
        }
    }
}


// MARK: - Delegate methods called on `centralQueue`
extension BluetoothManager: CBCentralManagerDelegate {
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        log.default("%@", #function)

        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else {
            return
        }

        for peripheral in peripherals {
            addPeripheral(peripheral, nil)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.default("%@: %@", #function, central.state.description)
        if case .poweredOn = central.state {
            autoConnectDevices()

            if isScanningEnabled || !hasDiscoveredAllAutoConnectDevices {
                central.scanForPeripherals()
            } else if central.isScanning {
                central.stopScan()
            }
        }

        for device in devices {
            device.centralManagerDidUpdateState(central)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        log.default("Discovered %@ at %@", peripheral, RSSI)

        addPeripheral(peripheral, advertisementData)

        // TODO: Should we keep scanning? There's no UI to remove a lost RileyLink, which could result in a battery drain due to indefinite scanning.
        if !isScanningEnabled && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.default("All peripherals discovered")
            central.stopScan()
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Notify the device so it can begin configuration
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.centralManager(central, didConnect: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
        }

        autoConnectDevices()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("%@: %@: %@", #function, peripheral, String(describing: error))

        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.centralManager(central, didFailToConnect: peripheral, error: error)
        }

        autoConnectDevices()
    }
}


extension BluetoothManager {
    public override var debugDescription: String {
        var report = [
            "## BluetoothManager",
            "central: \(central!)",
            "autoConnectIDs: \(autoConnectIDs)",
            "timerTickEnabled: \(timerTickEnabled)",
            "idleListeningState: \(idleListeningState)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension Notification.Name {
    public static let ManagerDevicesDidChange = Notification.Name("com.omnikit.OmniKit.DevicesDidChange")
}

extension BluetoothManager {
    public static let autoConnectIDsStateKey = "com.omnikit.OmniKit.AutoConnectIDs"
}

extension CBCentralManager {
    func scanForPeripherals(withOptions options: [String: Any]? = nil) {
        scanForPeripherals(withServices: [advertisedServiceUUID], options: options)
    }
}

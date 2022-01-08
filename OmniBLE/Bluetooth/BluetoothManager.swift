//
//  BluetoothManager.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 10/10/21.
//

import CoreBluetooth
import Foundation
import LoopKit
import os.log


protocol BluetoothManagerDelegate: AnyObject {

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral, or that it failed to do so

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, isReadyWithError error: Error?)

    /**
     Asks the delegate whether the discovered or restored peripheral should be connected

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: True if the peripheral should connect
     */
    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String : Any]?) -> Bool

    /// Informs the delegate that the bluetooth device has completed configuration
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the authentication characteristic
    func bluetoothManager(_ manager: BluetoothManager, didCompleteConfiguration peripheralManager: PeripheralManager)
}


class BluetoothManager: NSObject {

    var stayConnected: Bool {
        get {
            return lockedStayConnected.value
        }
        set {
            lockedStayConnected.value = newValue
        }
    }
    private let lockedStayConnected: Locked<Bool> = Locked(true)

    private var isPermanentlyDisconnecting: Bool = false

    weak var delegate: BluetoothManagerDelegate?

    private let log = OSLog(category: "BluetoothManager")

    private let concurrentReconnectSemaphore = DispatchSemaphore(value: 1)

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil

    /// Isolated to `managerQueue`
    private var peripheral: CBPeripheral? {
        get {
            return peripheralManager?.peripheral
        }
        set {
            guard let peripheral = newValue else {
                peripheralManager = nil
                return
            }

            if let peripheralManager = peripheralManager {
                peripheralManager.peripheral = peripheral
            } else {
                peripheralManager = PeripheralManager(
                    peripheral: peripheral,
                    configuration: .omnipod,
                    centralManager: manager
                )
            }
        }
    }

    var peripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
        set {
            lockedPeripheralIdentifier.value = newValue
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Isolated to `managerQueue`
    private var peripheralManager: PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            peripheralManager?.delegate = self

            peripheralIdentifier = peripheralManager?.peripheral.identifier
        }
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.randallknutson.OmniBLE.bluetoothManagerQueue", qos: .unspecified)

    override init() {
        super.init()

        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.randallknutson.OmniBLE"])
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.managerQueue_scanForPeripheral()
        }
    }

    // This is a actually `permanentDisconnect` - we do not plan on connecting to this device anymore
    func permanentDisconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        log.debug("permanentDisconnect called")

        // TODO: This could also be async?
        managerQueue.sync {
            if manager.isScanning {
                log.debug("permanentDisconnect - running stopScan")
                manager.stopScan()
            }

            if let peripheral = peripheral {
                isPermanentlyDisconnecting = true
                log.debug("permanentDisconnect - running cancelPeripheralConnection")
                manager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func reconnectPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        // Make sure only one reconnect loop is happening concurrently
        log.debug("reconnectPeripheral concurrency semaphore check")
        concurrentReconnectSemaphore.wait()
        log.debug("reconnectPeripheral concurrency semaphore check - is free, continuing")

        guard manager.state == .poweredOn else {
            log.debug("reconnectPeripheral error - manager.state != .poweredOn")
            concurrentReconnectSemaphore.signal()
            return
        }

        let currentState = peripheral?.state ?? .disconnected
        guard currentState != .connected else {
            if let _ = peripheral {
                log.debug("reconnectPeripheral error - peripheral is already connected %@", peripheral!)
            }
            concurrentReconnectSemaphore.signal()
            return
        }

        // Possible states are disconnected, disconnecting, connected and connecting
        // We guard against connected earlier and in case of connecting we only need to wait for the semaphore
        if currentState == .disconnected || currentState == .disconnecting {
            if let _ = peripheral {
                log.debug("reconnectPeripheral running managerQueue_scanForPeripheral for peripheral %@", peripheral!)
            }
            managerQueue.sync {
                log.debug("reconnectPeripheral - in managerQueue.sync")
                self.managerQueue_scanForPeripheral()
                log.debug("reconnectPeripheral - finished managerQueue.sync")
            }
        }

        // Release reconnect loop for other callers
        log.debug("reconnectPeripheral concurrency semaphore signaling")
        concurrentReconnectSemaphore.signal()
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard manager.state == .poweredOn else {
            return
        }

        let currentState = peripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        guard currentState != .connecting else {
            return
        }

        if let peripheral = manager.retrieveConnectedPeripherals(withServices: [
            OmnipodServiceUUID.advertisement.cbUUID,
            OmnipodServiceUUID.service.cbUUID
        ]).first,
        delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: nil)
        {
            log.debug("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
            self.peripheral = peripheral
            self.manager.connect(peripheral)
        } else {
            // TEST: There might be a race condition where PeripheralManager considers the device already connected, although it isn't
            // TODO: Investigate more
            // Related https://github.com/randallknutson/OmniBLE/pull/10#pullrequestreview-837692407
            if let peripheralID = peripheralIdentifier, let peripheral = manager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
                log.debug("Re-connecting to known peripheral %{public}@", peripheral.identifier.uuidString)
                self.peripheral = peripheral
                self.manager.connect(peripheral)
            } else {
                log.debug("Scanning for peripherals")
                manager.scanForPeripherals(withServices: [OmnipodServiceUUID.advertisement.cbUUID],
                options: nil
                )
            }
        }
    }

    /**

     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.

     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    fileprivate func scanAfterDelay() {
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 2)

            self.scanForPeripheral()
        }
    }

    // MARK: - Accessors

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isScanning = false
        managerQueue.sync {
            isScanning = manager.isScanning
        }
        return isScanning
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            peripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        peripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            if central.isScanning {
                central.stopScan()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("%{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: nil) {
                    log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                    self.peripheral = peripheral
                    // TODO: Maybe connect to peripheral if its state is disconnected?
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.info("%{public}@: %{public}@", #function, peripheral)
        if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: advertisementData) {
            self.peripheral = peripheral

            log.debug("connecting to peripheral %@", peripheral)
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@", #function, peripheral)
        if central.isScanning {
            central.stopScan()
        }

        peripheralManager?.centralManager(central, didConnect: peripheral)

        if case .poweredOn = manager.state, case .connected = peripheral.state, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = peripheralManager {
                self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
            }
        }

        // Make sure if permanent disconnect is requested, we are actually permanently clearing the peripheral
        if isPermanentlyDisconnecting {
            log.debug("isPermanentlyDisconnecting is true - nullifying peripheral")
            // nullify the peripheral if we don't want it anymore
            // TODO: check why stayConnected is never set?
            self.stayConnected = false
            self.peripheral = nil // this should also nullify peripheralManager and peripheralIdentifier
            log.debug("isPermanentlyDisconnecting done - setting isPermanentlyDisconnecting to false")
            self.isPermanentlyDisconnecting = false
        }

        if stayConnected {
            scanAfterDelay()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        peripheralManager?.centralManager(central, didFailToConnect: peripheral, error: error)

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
        }

        if stayConnected {
            scanAfterDelay()
        }
    }
}


extension BluetoothManager: PeripheralManagerDelegate {
    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {

    }

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager) {

    }

    func completeConfiguration(for manager: PeripheralManager) throws {
        self.delegate?.bluetoothManager(self, didCompleteConfiguration: manager)
    }

    // throws?
    func reconnectLatestPeripheral() {
        reconnectPeripheral()
    }

    func peripheralManager(_ manager: PeripheralManager, didUpdateNotificationStateFor characteristic: CBCharacteristic) {

    }

    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {

    }
}

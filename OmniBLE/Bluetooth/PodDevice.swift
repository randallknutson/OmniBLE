//
//  PodDevice.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/18/21.
//

import Foundation
import CoreBluetooth
import OSLog

public class PodDevice {
    let MAIN_SERVICE_UUID = "4024"
    let UNKNOWN_THIRD_SERVICE_UUID = "000A"
    let manager: PeripheralManager
    var sequenceNo: UInt32?
    var lotNo: UInt64?
//    let podId: UInt64
    
    private var serviceUUIDs: [CBUUID]

    private let log = OSLog(category: "OmniKitDevice")

    /// The queue used to serialize sessions and observe when they've drained
    private let sessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.omnikit.OmniKit.PodDevice.sessionQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    private var sessionQueueOperationCountObserver: NSKeyValueObservation!

    // Confined to `lock`
    private var idleListeningState: IdleListeningState = .disabled

    // Confined to `lock`
    private var lastIdle: Date?
    
    // Confined to `lock`
    // TODO: Tidy up this state/preference machine
    private var isIdleListeningPending = false

    // Confined to `lock`
    private var isTimerTickEnabled = true

    /// Serializes access to device state
    private var lock = os_unfair_lock()

    init(peripheralManager: PeripheralManager, advertisementData: [String : Any]?) {
        self.manager = peripheralManager
        sessionQueue.underlyingQueue = peripheralManager.queue
//        serviceUUIDs = advertisementData?["kCBAdvDataServiceUUIDs"] as! [CBUUID]
        serviceUUIDs = [CBUUID]()

        peripheralManager.delegate = self
        
        sessionQueueOperationCountObserver = sessionQueue.observe(\.operationCount, options: [.new]) { [weak self] (queue, change) in
            if let newValue = change.newValue, newValue == 0 {
                self?.log.debug("Session queue operation count is now empty")
                self?.assertIdleListening(forceRestart: true)
            }
        }
    }
    
    private func discoverData(advertisementData: [String: Any]) {
        // TODO:
//        try validateServiceUUIDs()
//        try validatePodId()
//        lotNo = parseLotNo()
//        sequenceNo = parseSeqNo()

    }
    
    private func validateServiceUUIDs() throws {
        if (serviceUUIDs.count != 7) {
            throw BLEErrors.DiscoveredInvalidPodException("Expected 9 service UUIDs, got \(serviceUUIDs.count)", serviceUUIDs)
        }
        if (serviceUUIDs[0].uuidString != MAIN_SERVICE_UUID) {
            // this is the service that we filtered for
            throw BLEErrors.DiscoveredInvalidPodException(
                "The first exposed service UUID should be 4024, got " + serviceUUIDs[0].uuidString,     serviceUUIDs
            )
        }
        // TODO understand what is serviceUUIDs[1]. 0x2470. Alarms?
        if (serviceUUIDs[2].uuidString != UNKNOWN_THIRD_SERVICE_UUID) {
            // constant?
            throw BLEErrors.DiscoveredInvalidPodException(
                "The third exposed service UUID should be 000a, got " + serviceUUIDs[2].uuidString,
                serviceUUIDs
            )
        }
    }
    
//    private func validatePodId() throws {
//        let hexPodId = serviceUUIDs[3].uuidString + serviceUUIDs[4].uuidString
//        let podId = UInt64(hexPodId, radix: 16)
//        if (self.podId != podId) {
//            throw BLEErrors.DiscoveredInvalidPodException(
//                "This is not the POD we are looking for: \(self.podId) . Found: \(podId ?? 0)/\(hexPodId)",
//                serviceUUIDs
//            )
//        }
//    }
    
    private func parseLotNo() -> UInt64? {
        print(serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString)
        let lotSeq: String = serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString + serviceUUIDs[7].uuidString
        return UInt64(lotSeq[lotSeq.startIndex..<lotSeq.index(lotSeq.startIndex, offsetBy: 10)], radix: 16)
    }

    private func parseSeqNo() -> UInt32? {
        let lotSeq: String = serviceUUIDs[7].uuidString + serviceUUIDs[8].uuidString
        return UInt32(lotSeq[lotSeq.index(lotSeq.startIndex, offsetBy: 2)..<lotSeq.endIndex], radix: 16)
    }

}

// MARK: - Peripheral operations. Thread-safe.
extension PodDevice {
    public var name: String? {
        return manager.peripheral.name
    }
    
    public var deviceURI: String {
        return "omnipod://\(name ?? peripheralIdentifier.uuidString)"
    }

    public var peripheralIdentifier: UUID {
        return manager.peripheral.identifier
    }

    public var peripheralState: CBPeripheralState {
        return manager.peripheral.state
    }

    public func readRSSI() {
        guard case .connected = manager.peripheral.state, case .poweredOn? = manager.central?.state else {
            return
        }
        manager.peripheral.readRSSI()
    }

    /// Asserts that the caller is currently on the session queue
    public func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }

    /// Schedules a closure to execute on the session queue after a specified time
    ///
    /// - Parameters:
    ///   - deadline: The time after which to execute
    ///   - execute: The closure to execute
    public func sessionQueueAsyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) {
        manager.queue.asyncAfter(deadline: deadline, execute: execute)
    }
}


// MARK: - Idle management
extension PodDevice {
    public enum IdleListeningState {
        case enabled(timeout: TimeInterval, channel: UInt8)
        case disabled
    }

    func setIdleListeningState(_ state: IdleListeningState) {
        os_unfair_lock_lock(&lock)
        let oldValue = idleListeningState
        idleListeningState = state
        os_unfair_lock_unlock(&lock)

        switch (oldValue, state) {
        case (.disabled, .enabled):
            assertIdleListening(forceRestart: true)
        case (.enabled, .enabled):
            assertIdleListening(forceRestart: false)
        default:
            break
        }
    }

    public func assertIdleListening(forceRestart: Bool = false) {
        os_unfair_lock_lock(&lock)
        guard case .enabled(timeout: let timeout, channel: let channel) = self.idleListeningState else {
            os_unfair_lock_unlock(&lock)
            return
        }

        guard case .connected = self.manager.peripheral.state, case .poweredOn? = self.manager.central?.state else {
            os_unfair_lock_unlock(&lock)
            return
        }

        guard forceRestart || (self.lastIdle ?? .distantPast).timeIntervalSinceNow < -timeout else {
            os_unfair_lock_unlock(&lock)
            return
        }

        guard !self.isIdleListeningPending else {
            os_unfair_lock_unlock(&lock)
            return
        }

        self.isIdleListeningPending = true
        os_unfair_lock_unlock(&lock)

//        self.manager.startIdleListening(idleTimeout: timeout, channel: channel) { (error) in
//            os_unfair_lock_lock(&self.lock)
//            self.isIdleListeningPending = false
//
//            if let error = error {
//                self.log.error("Unable to start idle listening: %@", String(describing: error))
//                os_unfair_lock_unlock(&self.lock)
//            } else {
//                self.lastIdle = Date()
//                self.log.debug("Started idle listening")
//                os_unfair_lock_unlock(&self.lock)
//                NotificationCenter.default.post(name: .DeviceDidStartIdle, object: self)
//            }
//        }
    }
}

// MARK: - Timer tick management
extension PodDevice {
    func setTimerTickEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        self.isTimerTickEnabled = enabled
        os_unfair_lock_unlock(&lock)
        self.assertTimerTick()
    }

    func assertTimerTick() {
        os_unfair_lock_lock(&self.lock)
        let isTimerTickEnabled = self.isTimerTickEnabled
        os_unfair_lock_unlock(&self.lock)

//        if isTimerTickEnabled != self.manager.timerTickEnabled {
//            self.manager.setTimerTickEnabled(isTimerTickEnabled)
//        }
    }
}

// MARK: - CBCentralManagerDelegate Proxying
extension PodDevice {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if case .poweredOn = central.state {
            assertIdleListening(forceRestart: false)
            assertTimerTick()
        }

        manager.centralManagerDidUpdateState(central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.debug("didConnect %@", peripheral)
        if case .connected = peripheral.state {
            assertIdleListening(forceRestart: false)
            assertTimerTick()
        }

        manager.centralManager(central, didConnect: peripheral)
        NotificationCenter.default.post(name: .DeviceConnectionStateDidChange, object: self)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.debug("didDisconnectPeripheral %@", peripheral)
        NotificationCenter.default.post(name: .DeviceConnectionStateDidChange, object: self)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.debug("didFailToConnect %@", peripheral)
        NotificationCenter.default.post(name: .DeviceConnectionStateDidChange, object: self)
    }
}


extension PodDevice: PeripheralManagerDelegate {
    func peripheralManager(_ manager: PeripheralManager, didUpdateNotificationStateFor characteristic: CBCharacteristic) {
        log.debug("Did didUpdateNotificationStateFor %@", characteristic)
    }
    
    // If PeripheralManager receives a response on the data queue, without an outstanding request,
    // it will pass the update to this method, which is called on the central's queue.
    // This is how idle listen responses are handled
    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        log.debug("Did UpdateValueFor %@", characteristic)
    }

    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        NotificationCenter.default.post(
            name: .DeviceRSSIDidChange,
            object: self,
            userInfo: [PodDevice.notificationRSSIKey: RSSI]
        )
    }

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager) {
        NotificationCenter.default.post(
            name: .DeviceNameDidChange,
            object: self,
            userInfo: nil
        )
    }

    func completeConfiguration(for manager: PeripheralManager) throws {
        // Read bluetooth version to determine compatibility
//        log.default("Reading firmware versions for PeripheralManager configuration")
//        let bleVersionString = try manager.readBluetoothFirmwareVersion(timeout: 1)
//        bleFirmwareVersion = BLEFirmwareVersion(versionString: bleVersionString)
//
//        let radioVersionString = try manager.readRadioFirmwareVersion(timeout: 1, responseType: bleFirmwareVersion?.responseType ?? .buffered)
//        radioFirmwareVersion = RadioFirmwareVersion(versionString: radioVersionString)
//
//        try manager.setOrangeNotifyOn()
    }
}


extension PodDevice {
    public static let notificationPacketKey = "com.omnikit.OmniKit.PodDevice.NotificationPacket"

    public static let notificationRSSIKey = "com.omnikit.OmniKit.PodDevice.NotificationRSSI"
}


extension Notification.Name {
    public static let DeviceConnectionStateDidChange = Notification.Name(rawValue: "com.omnikit.OmniKit.ConnectionStateDidChange")

    public static let DeviceDidStartIdle = Notification.Name(rawValue: "com.omnikit.OmniKit.DidStartIdle")

    public static let DeviceNameDidChange = Notification.Name(rawValue: "com.omnikit.OmniKit.NameDidChange")

    public static let DevicePacketReceived = Notification.Name(rawValue: "com.omnikit.OmniKit.PacketReceived")

    public static let DeviceRSSIDidChange = Notification.Name(rawValue: "com.omnikit.OmniKit.RSSIDidChange")

    public static let DeviceTimerDidTick = Notification.Name(rawValue: "com.omnikit.OmniKit.TimerTickDidChange")
    
    public static let DeviceStatusUpdated = Notification.Name(rawValue: "com.omnikit.OmniKit.DeviceStatusUpdated")

    public static let DeviceBatteryLevelUpdated = Notification.Name(rawValue: "com.omnikit.OmniKit.BatteryLevelUpdated")
}

//
//  Omnipod.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 10/11/21.
//

import Foundation
import CoreBluetooth
import LoopKit
import OSLog

public protocol OmnipodDelegate: AnyObject {
    func omnipod(_ omnipod: Omnipod)

    func omnipod(_ omnipod: Omnipod, didError error: Error)
}

public class Omnipod {
    let MAIN_SERVICE_UUID = "4024"
    let UNKNOWN_THIRD_SERVICE_UUID = "000A"
    var manager: PeripheralManager?
    var sequenceNo: UInt32?
    var lotNo: UInt64?
    var podId: UInt32? = nil
    
    private var pairNew = false
    
    private var serviceUUIDs: [CBUUID]

    private let log = OSLog(category: "Omnipod")

//    private let manager: PeripheralManager

    private let bluetoothManager = BluetoothManager()
    
    private let delegateQueue = DispatchQueue(label: "com.randallknutson.OmnipodKit.delegateQueue", qos: .unspecified)

    private var sessionQueueOperationCountObserver: NSKeyValueObservation!

    /// Serializes access to device state
    private var lock = os_unfair_lock()
    
    private let connectLock = NSCondition()
    
    /// The queue used to serialize sessions and observe when they've drained
    private let sessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.randallknutson.OmniBLE.OmnipodDevice.sessionQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    init(_ state: PodState?) {
        self.state = state
        self.serviceUUIDs = []

//        self.bluetoothManager.peripheralIdentifier = peripheralIdentifier
        self.podComms = PodComms(podState: state, lotNo: lotNo, lotSeq: sequenceNo)
        self.bluetoothManager.delegate = self
    }
    
    // Only valid to access on the session serial queue
    private var state: PodState? {
        didSet {
            if let newValue = state, newValue != oldValue {
                log.debug("Notifying delegate of new podState: %{public}@", String(reflecting: newValue))
//                delegate?.podComms(self, didChange: newValue)
            }
        }
    }
    
    public weak var delegate: OmnipodDelegate?
    
    public var podComms: PodComms

    func connectNew() throws {
        connectLock.lock()
        pairNew = true

        defer {
            pairNew = false
            connectLock.unlock()
        }

        bluetoothManager.scanForPeripheral()

        let signaled = connectLock.wait(until: Date(timeIntervalSinceNow: 10))
        
        guard signaled else {
            throw PeripheralManagerError.notReady
        }
    }

    public func resumeScanning() {
        if stayConnected {
            bluetoothManager.scanForPeripheral()
        }
    }

    public func disconnect() {
        bluetoothManager.disconnect()
    }

    public var isScanning: Bool {
        return bluetoothManager.isScanning
    }

    public var peripheralIdentifier: UUID? {
        get {
            return bluetoothManager.peripheralIdentifier
        }
        set {
            bluetoothManager.peripheralIdentifier = newValue
        }
    }

    public var stayConnected: Bool {
        get {
            return bluetoothManager.stayConnected
        }
        set {
            bluetoothManager.stayConnected = newValue

            if newValue {
                bluetoothManager.scanForPeripheral()
            }
        }
    }
    
}

// MARK: - Reading pump data

extension Omnipod {
    private func discoverData(advertisementData: [String: Any]) throws {
        serviceUUIDs = advertisementData["kCBAdvDataServiceUUIDs"] as! [CBUUID]

        try validateServiceUUIDs()
        parsePodId()
        lotNo = parseLotNo()
        sequenceNo = parseSeqNo()
    }
    
    private func validateServiceUUIDs() throws {
        // For some reason the pod simulator doesn't have two values.
        if (serviceUUIDs.count == 7) {
            serviceUUIDs.append(CBUUID(string: "abcd"))
            serviceUUIDs.append(CBUUID(string: "dcba"))
        }
        if (serviceUUIDs.count != 9) {
            throw BluetoothErrors.DiscoveredInvalidPodException("Expected 9 service UUIDs, got \(serviceUUIDs.count)", serviceUUIDs)
        }
        if (serviceUUIDs[0].uuidString != MAIN_SERVICE_UUID) {
            // this is the service that we filtered for
            throw BluetoothErrors.DiscoveredInvalidPodException(
                "The first exposed service UUID should be 4024, got " + serviceUUIDs[0].uuidString, serviceUUIDs
            )
        }
        // TODO understand what is serviceUUIDs[1]. 0x2470. Alarms?
        if (serviceUUIDs[2].uuidString != UNKNOWN_THIRD_SERVICE_UUID) {
            // constant?
            throw BluetoothErrors.DiscoveredInvalidPodException(
                "The third exposed service UUID should be 000a, got " + serviceUUIDs[2].uuidString, serviceUUIDs
            )
        }
    }
    
    private func parsePodId() {
        podId = UInt32(serviceUUIDs[3].uuidString + serviceUUIDs[4].uuidString, radix: 16)
    }
    
    private func parseLotNo() -> UInt64? {
        print(serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString)
        let lotNo: String = serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString + serviceUUIDs[7].uuidString
        return UInt64(lotNo[lotNo.startIndex..<lotNo.index(lotNo.startIndex, offsetBy: 10)], radix: 16)
    }

    private func parseSeqNo() -> UInt32? {
        let lotSeq: String = serviceUUIDs[7].uuidString + serviceUUIDs[8].uuidString
        return UInt32(lotSeq[lotSeq.index(lotSeq.startIndex, offsetBy: 2)..<lotSeq.endIndex], radix: 16)
    }

}

// MARK: - Command session management
// CommandSessions are a way to serialize access to the Omnipod command/response facility.
// All commands that send data out on the data characteristic need to be in a command session.
extension Omnipod {
    public func runSession(withName name: String, _ block: @escaping () -> Void) {
        guard let manager = manager else { return }
        self.log.default("Scheduling session %{public}@", name)
        sessionQueue.addOperation(manager.configureAndRun({ [weak self] (manager) in
            self?.log.default("======================== %{public}@ ===========================", name)
            block()
            self?.log.default("------------------------ %{public}@ ---------------------------", name)
        }))
    }
}


// MARK: - BluetoothManagerDelegate

extension Omnipod: BluetoothManagerDelegate {
    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, isReadyWithError error: Error?) {
        if (error == nil) {
            podComms.manager = peripheralManager
        }
    }
    
    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String : Any]?) -> Bool {
        do {
            if (advertisementData == nil) {
                return true
            }
            try discoverData(advertisementData: advertisementData!)
            if (
                (pairNew && podId == Ids.notActivated().toUInt32()) ||
                (state?.address != nil && state?.address == podId)
            ) {
                return true
            }
            return false
        }
        catch {
            return false
        }
    }
    
    func bluetoothManager(_ manager: BluetoothManager, didCompleteConfiguration peripheralManager: PeripheralManager) {
        peripheralManager.runSession(withName: "Complete pod configuration") { [weak self] in
            do {
                guard let self = self else { return }
                try peripheralManager.sendHello(Ids.controllerId().address)
                try peripheralManager.enableNotifications()
                if (!self.podComms.isPaired) {
                    let ids = Ids(podState: self.state)
                    try self.podComms.pairPod(ids: ids)
                }
                else {
                    try self.podComms.establishSession(msgSeq: 1)
                }

                self.connectLock.lock()
                self.connectLock.broadcast()
                self.connectLock.unlock()
            } catch let error {
                self?.log.error("Error completing configuration: %@", String(describing: error))
            }
        }
    }
}

extension Omnipod: CustomDebugStringConvertible {
    public var debugDescription: String {
        return [
            "## Omnipod",
            "* MAIN_SERVICE_UUID: \(MAIN_SERVICE_UUID)",
            "* UNKNOWN_THIRD_SERVICE_UUID: \(UNKNOWN_THIRD_SERVICE_UUID)",
            "* sequenceNo: \(String(describing: sequenceNo))",
            "* lotNo: \(String(describing: lotNo))",
            "* podId: \(String(describing: podId))",
            "* serviceUUIDs: \(String(reflecting: serviceUUIDs))",
            "* state: \(String(reflecting: state))",
        ].joined(separator: "\n")
    }
}

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

public enum OmnipodStatus {
    case Unpaired
    case Paired
    case LumpOfCoal
}

public class Omnipod {
    let MAIN_SERVICE_UUID = "4024"
    let UNKNOWN_THIRD_SERVICE_UUID = "000A"
    var manager: PeripheralManager?
    var peripheral: CBPeripheral
    var sequenceNo: UInt32?
    var lotNo: UInt64?
    var podId: UInt32? = nil
    var status: OmnipodStatus = .Unpaired
    
    private var serviceUUIDs: [CBUUID]
    
    public init(peripheral: CBPeripheral, advertisementData: [String: Any]?) throws {
        self.peripheral = peripheral
        
        if (advertisementData != nil) {
            serviceUUIDs = advertisementData!["kCBAdvDataServiceUUIDs"] as! [CBUUID]
            try validateServiceUUIDs()
            podId = self.parsePodId()
            lotNo = self.parseLotNo()
            sequenceNo = self.parseSeqNo()
            status = podId == Ids.notActivated().toUInt32() ? .Unpaired : .Paired
        }
        else {
            status = .Paired
            serviceUUIDs = []
        }
    }

    private let log = OSLog(category: "Omnipod")

    private let delegateQueue = DispatchQueue(label: "com.randallknutson.OmnipodKit.delegateQueue", qos: .unspecified)

    private var sessionQueueOperationCountObserver: NSKeyValueObservation!

    /// Serializes access to device state
    private var lock = os_unfair_lock()
    
    /// The queue used to serialize sessions and observe when they've drained
    private let sessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.randallknutson.OmniBLE.OmnipodDevice.sessionQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

//    init(_ state: PodState?) {
//        self.state = state
//    }
    
    func connect(state: PodState?) {
        var newState = state
        if (lotNo != nil) {
            newState?.lotNo = lotNo
        }
        if (sequenceNo != nil) {
            newState?.sequenceNo = sequenceNo
        }
        self.podComms = PodComms(podState: newState)
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
    
    public var podComms: PodComms?

}

// MARK: - Reading pump data

extension Omnipod {
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
    
    private func parsePodId() -> UInt32? {
        return UInt32(serviceUUIDs[3].uuidString + serviceUUIDs[4].uuidString, radix: 16)
    }
    
    private func parseLotNo() -> UInt64? {
        print(serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString)
        let lotNo: String = serviceUUIDs[5].uuidString + serviceUUIDs[6].uuidString + serviceUUIDs[7].uuidString
        return UInt64(lotNo[lotNo.startIndex..<lotNo.index(lotNo.startIndex, offsetBy: 10)], radix: 16)
    }

    private func parseSeqNo() -> UInt32? {
        let sequenceNo: String = serviceUUIDs[7].uuidString + serviceUUIDs[8].uuidString
        return UInt32(sequenceNo[sequenceNo.index(sequenceNo.startIndex, offsetBy: 2)..<sequenceNo.endIndex], radix: 16)
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

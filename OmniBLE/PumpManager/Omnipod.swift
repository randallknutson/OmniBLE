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
    var manager: PeripheralManager
    var advertisement: PodAdvertisement?

    private var pairNew = false

    private let log = OSLog(category: "Omnipod")

//    private let manager: PeripheralManager

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
    
    init(peripheralManager: PeripheralManager, advertisement: PodAdvertisement?) {
        self.manager = peripheralManager
        sessionQueue.underlyingQueue = peripheralManager.queue
        
        self.advertisement = advertisement

        peripheralManager.delegate = self

        sessionQueueOperationCountObserver = sessionQueue.observe(\.operationCount, options: [.new]) { [weak self] (queue, change) in
            if let newValue = change.newValue, newValue == 0 {
                self?.log.debug("Session queue operation count is now empty")
            }
        }
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

}

// MARK: - Command session management
// CommandSessions are a way to serialize access to the Omnipod command/response facility.
// All commands that send data out on the data characteristic need to be in a command session.
extension Omnipod {
    public func runSession(withName name: String, _ block: @escaping () -> Void) {
        self.log.default("Scheduling session %{public}@", name)
        sessionQueue.addOperation(manager.configureAndRun({ [weak self] (manager) in
            self?.log.default("======================== %{public}@ ===========================", name)
            block()
            self?.log.default("------------------------ %{public}@ ---------------------------", name)
        }))
    }
}

// MARK: - PeripheralManagerDelegate

extension Omnipod: PeripheralManagerDelegate {
    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        log.debug("peripheralManager didUpdateValueFor")
    }
    
    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        log.debug("peripheralManager didReadRSSI")
    }
    
    func peripheralManagerDidUpdateName(_ manager: PeripheralManager) {
        log.debug("peripheralManagerDidUpdateName")
    }
    
    func completeConfiguration(for manager: PeripheralManager) throws {
        log.debug("completeConfiguration")
    }
    
    func reconnectLatestPeripheral() {
        log.debug("reconnectLatestPeripheral")
    }
    
}

// MARK: - BluetoothManagerDelegate

//extension Omnipod: BluetoothManagerDelegate {
//    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, isReadyWithError error: Error?) {
//        if (error == nil) {
//            //podComms.manager = peripheralManager
//        }
//    }
//
//    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String : Any]?) -> Bool {
//        log.debug("shouldConnectPeripheral: %{public}@", peripheral)
////        do {
//            if (advertisementData == nil) {
//                return true
//            }
////            try discoverData(advertisementData: advertisementData!)
//            if (
//                (pairNew && podId == Ids.notActivated().toUInt32()) ||
//                (state?.address != nil && state?.address == podId)
//            ) {
//                return true
//            }
//            return false
////        }
////        catch {
////            return false
////        }
//    }
//
//    func bluetoothManager(_ manager: BluetoothManager, didCompleteConfiguration peripheralManager: PeripheralManager) {
//        peripheralManager.runSession(withName: "Complete pod configuration") { [weak self] in
////            do {
////                guard let self = self else { return }
////                try peripheralManager.sendHello(Ids.controllerId().address)
////                try peripheralManager.enableNotifications()
////                if (!self.podComms.isPaired) {
////                    let ids = Ids(podState: self.state)
////                    try self.podComms.pairPod(ids: ids)
////                }
////                else {
////                    try self.podComms.establishSession(msgSeq: 1)
////                }
////
////                self.connectLock.lock()
////                self.connectLock.broadcast()
////                self.connectLock.unlock()
////            } catch let error {
////                self?.log.error("Error completing configuration: %@", String(describing: error))
////            }
//        }
//    }
//}

extension Omnipod: CustomDebugStringConvertible {
    public var debugDescription: String {
        return [
            "## Omnipod",
//            "* sequenceNo: \(String(describing: sequenceNo))",
//            "* lotNo: \(String(describing: lotNo))",
//            "* podId: \(String(describing: podId))",
//            "* state: \(String(reflecting: state))",
        ].joined(separator: "\n")
    }
}

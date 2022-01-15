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


public class Omnipod {
    var manager: PeripheralManager
    var advertisement: PodAdvertisement?

    private let log = OSLog(category: "Omnipod")

//    private let manager: PeripheralManager

//    private let delegateQueue = DispatchQueue(label: "com.randallknutson.OmnipodKit.delegateQueue", qos: .unspecified)
//
//    private var sessionQueueOperationCountObserver: NSKeyValueObservation!
//
//    /// Serializes access to device state
//    private var lock = os_unfair_lock()

//    /// The queue used to serialize sessions and observe when they've drained
//    private let sessionQueue: OperationQueue = {
//        let queue = OperationQueue()
//        queue.name = "com.randallknutson.OmniBLE.OmnipodDevice.sessionQueue"
//        queue.maxConcurrentOperationCount = 1
//
//        return queue
//    }()
    
    init(peripheralManager: PeripheralManager, advertisement: PodAdvertisement?) {
        self.manager = peripheralManager        
        self.advertisement = advertisement
    }
}


//// MARK: - Command session management
//// CommandSessions are a way to serialize access to the Omnipod command/response facility.
//// All commands that send data out on the data characteristic need to be in a command session.
//extension Omnipod {
//    public func runSession(withName name: String, _ block: @escaping () -> Void) {
//        self.log.default("Scheduling session %{public}@", name)
//        sessionQueue.addOperation(manager.configureAndRun({ [weak self] (manager) in
//            self?.log.default("======================== %{public}@ ===========================", name)
//            block()
//            self?.log.default("------------------------ %{public}@ ---------------------------", name)
//        }))
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

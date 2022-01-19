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

    init(peripheralManager: PeripheralManager, advertisement: PodAdvertisement?) {
        self.manager = peripheralManager        
        self.advertisement = advertisement
    }
}


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

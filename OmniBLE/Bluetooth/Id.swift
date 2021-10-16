//
//  Id.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/5/21.
//

import Foundation

class Id {
    static private let PERIPHERAL_NODE_INDEX = 1

    static func fromInt(_ v: Int32) -> Id {
        var value = v
        return Id(Data(bytes: &value, count: 4))
    }

    static func fromLong(_ v: Int64) -> Id {
        var value = v
        return Id(Data(bytes: &value, count: 8))
    }

    
    let address: Data
    
    init(_ address: Data) {
        guard address.count == 4 else {
            // TODO: Should probably throw an error here.
            //        require(address.size == 4)
            self.address = Data([0x00, 0x00, 0x00, 0x00])
            return
        }
        self.address = address
    }

    /**
     * Used to obtain podId from controllerId
     * The original PDM seems to rotate over 3 Ids:
     * controllerID+1, controllerID+2 and controllerID+3
     */
    func increment() -> Id {
        var nodeId = address
        nodeId[3] = UInt8((Int(nodeId[3]) & -4))
        nodeId[3] = UInt8((Int(nodeId[3]) | Id.PERIPHERAL_NODE_INDEX))
        return Id(nodeId)
    }

    // TODO:
//    override func toString(): String {
//        val asInt = ByteBuffer.wrap(address).int
//        return "$asInt/${address.toHex()}"
//    }

    func toInt64() -> Int64 {
        return address.withUnsafeBytes { pointer in
            return pointer.load(as: Int64.self)
        }
    }
//
    // TODO:
//    override func equals(other: Any?): Boolean {
//        if (this === other) return true
//        if (javaClass != other?.javaClass) return false
//
//        other as Id
//
//        if (!address.contentEquals(other.address)) return false
//
//        return true
//    }
//
//    override func hashCode() -> Int32 {
//        return address.contentHashCode()
//    }
}

//
//  Id.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/5/21.
//

import Foundation

class Id {
    static private let PERIPHERAL_NODE_INDEX = 1

    static func fromInt(_ v: Int) -> Id {
        return Id(Data(bigEndian: v).subdata(in: 4..<8))
    }

    static func fromLong(_ v: UInt32) -> Id {
        return Id(Data(bigEndian: v))
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
        var val = address.toBigEndian(Int.self)
        val += 1
        if (val >= 4246) {
            val = 4243
        }
        return Id.fromInt(val)
    }

    // TODO:
//    override func toString(): String {
//        val asInt = ByteBuffer.wrap(address).int
//        return "$asInt/${address.toHex()}"
//    }

    func toInt64() -> Int64 {
        return address.toBigEndian(Int64.self)
    }

    
    func toUInt32() -> UInt32 {
        return address.toBigEndian(UInt32.self)
    }
}

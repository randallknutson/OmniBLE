//
//  Id.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/5/21.
//

import Foundation

class Id {
    
    static private let PERIPHERAL_NODE_INDEX: UInt8 = 1

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
        var nodeId = address
        
        //Zero out last 2 bits on right which would round down in sequence of {4, 8, 12, 16, 20, ...}
        nodeId[3] = UInt8(Int(nodeId[3]) & -4)
        
        //Increment by adding 1
        nodeId[3] = nodeId[3] | Id.PERIPHERAL_NODE_INDEX
        return Id(nodeId)
    }
    
    /*
     TODO: the above implementation is ported from AndroidAPS while we implemented the version below.
     It is not clear if skipping every 4 numbers above is intentional or a bug. It would be preferred to use the
     AndroidAPS version though until we can successfully pair so we can send identical data payloads.
     */
    /*
    func increment() -> Id {
        var val = address.toBigEndian(Int.self)
        val += 1
        if (val >= 4246) {
            val = 4243
        }
        return Id.fromInt(val)
    }
     */
     
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

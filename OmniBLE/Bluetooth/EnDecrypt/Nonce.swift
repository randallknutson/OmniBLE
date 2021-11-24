//
//  Nonce.swift
//  OmniBLE
//
//  Created by Randall Knutson on 11/4/21.
//

import Foundation

class Nonce {
    let prefix: Data
    var sqn: Int
    
    init (prefix: Data, sqn: Int) {
        guard prefix.count == 8 else { fatalError("Nonce prefix should be 8 bytes long") }
        self.prefix = prefix
        self.sqn = sqn
    }

    func increment(podReceiving: Bool) -> Data {
        sqn += 1
        var ret = Data(bigEndian: sqn)
            .subdata(in: 3..<8)
        if (podReceiving) {
            ret[0] = UInt8(ret[0] & 127)
        } else {
            ret[0] = UInt8(ret[0] | 128)
        }
        return prefix + ret
    }
}

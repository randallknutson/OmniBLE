//
//  PayloadSplitJoinTests.swift
//  OmniBLE
//
//  Created by Bill Gestrich on 12/11/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//

import XCTest
@testable import OmniBLE

class PayloadSplitJoinTests: XCTestCase {

    func testSplitAndJoinBack() {
        for _ in 0...250 {
            let payload = Data(Int.random(in: 1..<100))
            let splitter = PayloadSplitter(payload: payload)
            let packets = splitter.splitInPackets()
            let joiner = try! PayloadJoiner(firstPacket: packets[0].toData())
            for p in packets[1...] {
                try! joiner.accumulate(packet: p.toData())
            }
            let got = try! joiner.finalize()
            assert(got.hexadecimalString == payload.hexadecimalString)
        }
    }
}

//
//  PayloadJoiner.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/11/21.
//

import Foundation

class PayloadJoiner {
    var oneExtraPacket: Bool
    let fullFragments: Int
    var crc: Data?
    private var expectedIndex = 0
    private var fragments: Array<BlePacket> = Array<BlePacket>()

    init(firstPacket: Data) throws {
        let firstPacket = try FirstBlePacket.parse(payload: firstPacket)
        fragments.append(firstPacket)
        fullFragments = firstPacket.fullFragments
        crc = firstPacket.crc32
        oneExtraPacket = firstPacket.oneExtraPacket
    }

    func accumulate(packet: Data) throws {
        if (packet.count < 3) { // idx, size, at least 1 byte of payload
            throw BLEErrors.IncorrectPacketException(packet, (expectedIndex + 1))
        }
        let idx = Int(packet[0])
        if (idx != expectedIndex + 1) {
            throw BLEErrors.IncorrectPacketException(packet, (expectedIndex + 1))
        }
        expectedIndex += 1
        switch idx{
        case let index where index < fullFragments:
            fragments.append(try MiddleBlePacket.parse(payload: packet))
        case let index where index == fullFragments:
            let lastPacket = try LastBlePacket.parse(payload: packet)
            fragments.append(lastPacket)
            crc = lastPacket.crc32
            oneExtraPacket = lastPacket.oneExtraPacket
        case let index where index == fullFragments + 1 && oneExtraPacket:
            fragments.append(try LastOptionalPlusOneBlePacket.parse(payload: packet))
        case let index where index > fullFragments:
            throw BLEErrors.IncorrectPacketException(packet, idx)
        default:
            throw BLEErrors.IncorrectPacketException(packet, idx)
        }
    }

    func finalize() throws -> Data {
        let payloads = fragments.map { x in x.payload }
        let bb = payloads.reduce(Data(), { acc, elem in acc + elem })
        if (bb.crc32() != crc) {
            print("uh oh")
//            throw CrcMismatchException(bb.crc32(), crc, bb)
        }
        return bb
    }
}

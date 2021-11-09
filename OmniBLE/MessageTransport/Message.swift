//
//  Message.swift
//  OmniKit
//
//  Created by Pete Schwamb on 10/14/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation

enum MessageType: UInt8 {
    case CLEAR = 0, ENCRYPTED, SESSION_ESTABLISHMENT, PAIRING
}

public enum MessageError: Error {
    case notEnoughData
    case invalidCrc
    case invalidSequence
    case invalidAddress(address: UInt32)
    case parsingError(offset: Int, data: Data, error: Error)
    case unknownValue(value: UInt8, typeDescription: String)
    case validationFailed(description: String)
}

struct Message {
    let MAGIC_PATTERN = "TW" // all messages start with this string
    let HEADER_SIZE = 16

    let type: MessageType
    var source: Id = Id.fromInt(CONTROLLER_ID)
    let destination: Id
    var messageBlocks: [MessageBlock] = []
    var payload: Data = Data()
    let sequenceNumber: UInt8
    let ack: Bool
    let ackNumber: UInt8
    let eqos: Int16
    let priority: Bool
    let lastMessage: Bool
    let gateway: Bool
    let sas: Bool // TODO: understand, seems to always be true
    let tfs: Bool // TODO: understand, seems to be false
    let version: Int16

    init(type: MessageType, address: UInt32, messageBlocks: [MessageBlock]? = nil, payload: Data? = nil, sequenceNumber: UInt8, ack: Bool = false, ackNumber: UInt8 = 0, eqos: Int16 = 0, priority: Bool = false, lastMessage: Bool = false, gateway: Bool = false, sas: Bool = true, tfs: Bool = false, version: Int16 = 0) {
        self.type = type
        self.destination = Id.fromLong(address)
        self.sequenceNumber = sequenceNumber
        self.ack = ack
        self.ackNumber = ackNumber
        self.eqos = eqos
        self.priority = priority
        self.lastMessage = lastMessage
        self.gateway = gateway
        self.sas = sas
        self.tfs = tfs
        self.version = version
        if let messageBlocks = messageBlocks {
            self.messageBlocks = messageBlocks
            self.payload = Data()
            for cmd in messageBlocks {
                self.payload.append(cmd.data)
            }
        }

        if let payload = payload  {
            self.payload = payload
            do {
                self.messageBlocks = try Message.decodeBlocks(data: payload)
            }
            catch {
                self.messageBlocks = []
            }
        }
    }
    
    init(encodedData: Data) throws {
        guard encodedData.count >= HEADER_SIZE else {
            throw BluetoothErrors.CouldNotParseMessageException("Incorrect header size")
        }

        guard (String(data: encodedData.subdata(in: 0..<2), encoding: .utf8) == MAGIC_PATTERN) else {
            throw BluetoothErrors.CouldNotParseMessageException("Magic pattern mismatch")
        }
        let payloadData = encodedData
        
        let f1 = Flag(payloadData[2])
        self.sas = f1.get(3) != 0
        self.tfs = f1.get(4) != 0
        self.version = Int16(((f1.get(0) << 2) | (f1.get(1) << 1) | (f1.get(2) << 0)))
        self.eqos = Int16((f1.get(7) | (f1.get(6) << 1) | (f1.get(5) << 2)))

        let f2 = Flag(payloadData[3])
        self.ack = f2.get(0) != 0
        self.priority = f2.get(1) != 0
        self.lastMessage = f2.get(2) != 0
        self.gateway = f2.get(3) != 0
        self.type = MessageType(rawValue: UInt8(f1.get(7) | (f1.get(6) << 1) | (f1.get(5) << 2) | (f1.get(4) << 3))) ?? .CLEAR
        if (version != 0) {
            throw BluetoothErrors.CouldNotParseMessageException("Wrong version")
        }
        self.sequenceNumber = payloadData[4]
        self.ackNumber = payloadData[5]
        let size = (UInt16(payloadData[6]) << 3) | (UInt16(payloadData[7]) >> 5)
        guard encodedData.count >= (Int(size) + HEADER_SIZE) else {
            throw BluetoothErrors.CouldNotParseMessageException("Wrong payload size")
        }
        self.source = Id(encodedData.subdata(in: 8..<12))
        self.destination = Id(encodedData.subdata(in: 12..<16))

        let payloadEnd = Int(16 + size + (type == MessageType.ENCRYPTED ? 8 : 0))
        self.payload = encodedData.subdata(in: 16..<payloadEnd)
        do {
            self.messageBlocks = try Message.decodeBlocks(data: payload)
        }
        catch {
            self.messageBlocks = []
        }
    }
    
    static private func decodeBlocks(data: Data) throws -> [MessageBlock]  {
        var blocks = [MessageBlock]()
        var idx = 0
        repeat {
            guard let blockType = MessageBlockType(rawValue: data[idx]) else {
                throw MessageBlockError.unknownBlockType(rawVal: data[idx])
            }
            do {
                let block = try blockType.blockType.init(encodedData: Data(data.suffix(from: idx)))
                blocks.append(block)
                idx += Int(block.data.count)
            } catch (let error) {
                throw MessageError.parsingError(offset: idx, data: data.suffix(from: idx), error: error)
            }
        } while idx < data.count
        return blocks
    }
    
    func asData(forEncryption: Bool = false) -> Data {
        var bb = Data(capacity: 16 + payload.count)
        bb.append(MAGIC_PATTERN.data(using: .utf8)!)

        let f1 = Flag()
        f1.set(0, self.version & 4 != 0)
        f1.set(1, self.version & 2 != 0)
        f1.set(2, self.version & 1 != 0)
        f1.set(3, self.sas)
        f1.set(4, self.tfs)
        f1.set(5, self.eqos & 4 != 0)
        f1.set(6, self.eqos & 2 != 0)
        f1.set(7, self.eqos & 1 != 0)

        let f2 = Flag()
        f2.set(0, self.ack)
        f2.set(1, self.priority)
        f2.set(2, self.lastMessage)
        f2.set(3, self.gateway)
        f2.set(4, self.type.rawValue & 8 != 0)
        f2.set(5, self.type.rawValue & 4 != 0)
        f2.set(6, self.type.rawValue & 2 != 0)
        f2.set(7, self.type.rawValue & 1 != 0)

        bb.append(f1.value)
        bb.append(f2.value)
        bb.append(self.sequenceNumber)
        bb.append(self.ackNumber)
        let size = payload.count - ((type == MessageType.ENCRYPTED && !forEncryption) ? 8 : 0)
        bb.append(UInt8(size >> 3))
        bb.append(UInt8((size << 5) & 0xff))
        bb.append(self.source.address)
        bb.append(self.destination.address)

        bb.append(payload)

        return bb
    }
    
    var fault: DetailedStatus? {
        if messageBlocks.count > 0 && messageBlocks[0].blockType == .podInfoResponse,
            let infoResponse = messageBlocks[0] as? PodInfoResponse,
            infoResponse.podInfoResponseSubType == .detailedStatus,
            let detailedStatus = infoResponse.podInfo as? DetailedStatus,
            detailedStatus.isFaulted
        {
            return detailedStatus
        } else {
            return nil
        }
    }
}

extension Message: CustomDebugStringConvertible {
    var debugDescription: String {
        let sequenceNumberStr = String(format: "%02d", sequenceNumber)
        return "Message(\(destination.address.hexadecimalString) seq:\(sequenceNumberStr) \(messageBlocks))"
    }
}

private class Flag {
    var value: UInt8
    
    init(_ value: UInt8 = 0) {
        self.value = value
    }
    
    func set(_ idx: UInt8, _ set: Bool) {
        let mask: UInt8 = 1 << (7 - idx)
        if (!set) {
            return
        }
        value = value | mask
    }

    func get(_ idx: UInt8) -> UInt8 {
        let mask: UInt8 = 1 << (7 - idx)
        if (value & mask == 0) {
            return 0
        }
        return 1
    }
}

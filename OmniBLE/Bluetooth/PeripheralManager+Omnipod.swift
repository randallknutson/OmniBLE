//
//  PeripheralManager+Omnipod.swift
//  OmniBLE
//
//  Created by Randall Knutson on 11/2/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//


protocol MessageResult {
    
}

struct MessageSendFailure: MessageResult {
    var error: Error
}

struct MessageSendSuccess: MessageResult {
    
}

extension PeripheralManager {
    
    /// - Throws: PeripheralManagerError
    func sendHello(_ controllerId: Data) throws {
        dispatchPrecondition(condition: .onQueue(queue))
                
        log.debug("Sending Hello %s", controllerId.hexadecimalString)
        guard let characteristic = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }

        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, for: characteristic, type: .withResponse, timeout: 5)
    }
    
    func enableNotifications() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let cmdChar = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        guard let dataChar = peripheral.getDataCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        try setNotifyValue(true, for: cmdChar, timeout: .seconds(2))
        try setNotifyValue(true, for: dataChar, timeout: .seconds(2))
    }
        
    /// - Throws: PeripheralManagerError
    func sendMessage(_ message: MessagePacket, _ forEncryption: Bool = false) throws -> MessageResult {
        dispatchPrecondition(condition: .onQueue(queue))

        var result: MessageResult = MessageSendSuccess()
        
        do {
            try sendCommandType(PodCommand.RTS, timeout: 5)
            try readCommandType(PodCommand.CTS, timeout: 5)

            let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption))
            let packets = splitter.splitInPackets()

            for packet in packets {
                try sendData(packet.toData(), timeout: 5)
                try self.peekForNack()
            }

            try readCommandType(PodCommand.SUCCESS, timeout: 5)
        }
        catch {
            result = MessageSendFailure(error: error)
        }

        return result
    }
    
    /// - Throws: PeripheralManagerError
    func readMessage(_ readRTS: Bool = true) throws -> MessagePacket? {
        dispatchPrecondition(condition: .onQueue(queue))

        var packet: MessagePacket?

        do {
            if (readRTS) {
                try readCommandType(PodCommand.RTS)
            }
            
            try sendCommandType(PodCommand.CTS)

            var expected: UInt8 = 0
            let firstPacket = try readData(sequence: expected, timeout: 5)

            guard let _ = firstPacket else {
                return nil
            }

            let joiner = try PayloadJoiner(firstPacket: firstPacket!)

            for _ in 1...joiner.fullFragments {
                expected += 1
                guard let packet = try readData(sequence: expected, timeout: 5) else { return nil }
                try joiner.accumulate(packet: packet)
            }
            if (joiner.oneExtraPacket) {
                expected += 1
                guard let packet = try readData(sequence: expected, timeout: 5) else { return nil }
                try joiner.accumulate(packet: packet)
            }
            let fullPayload = try joiner.finalize()
            try  sendCommandType(PodCommand.SUCCESS)
            packet = try MessagePacket.parse(payload: fullPayload)
        }
        catch {
            print(error)
            try? sendCommandType(PodCommand.NACK)
            throw PeripheralManagerError.incorrectResponse
        }

        return packet
    }

    /// - Throws: PeripheralManagerError
    func peekForNack() throws -> Void {
        dispatchPrecondition(condition: .onQueue(queue))

        if cmdQueue.contains(where: { cmd in
            return cmd[0] == PodCommand.NACK.rawValue
        }) {
            throw PeripheralManagerError.nack
        }
    }
    
    /// - Throws: PeripheralManagerError
    func sendCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws  {
        dispatchPrecondition(condition: .onQueue(queue))
        
        guard let characteristic = peripheral.getCommandCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        log.debug("Writing Command Value %@", Data([command.rawValue]).hexadecimalString)
        
        try writeValue(Data([command.rawValue]), for: characteristic, type: .withResponse, timeout: timeout)
    }
    
    /// - Throws: PeripheralManagerError
    func readCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        log.debug("Read Command %@", Data([command.rawValue]).hexadecimalString)
        
        // Wait for data to be read.
        queueLock.lock()
        if (cmdQueue.count == 0) {
            queueLock.wait(until: Date().addingTimeInterval(timeout))
        }
        queueLock.unlock()

        commandLock.lock()
        defer {
            commandLock.unlock()
        }

        if (cmdQueue.count > 0) {
            let value = cmdQueue.remove(at: 0)

            if command.rawValue != value[0] {
                throw PeripheralManagerError.incorrectResponse
            }
            return
        }

        throw PeripheralManagerError.emptyValue
    }

    /// - Throws: PeripheralManagerError
    func sendData(_ value: Data, timeout: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        
        guard let characteristic = peripheral.getDataCharacteristic() else {
            throw PeripheralManagerError.notReady
        }
        
        log.debug("Writing Data Value %@", value.hexadecimalString)
        
        try writeValue(value, for: characteristic, type: .withResponse, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func readData(sequence: UInt8, timeout: TimeInterval) throws -> Data? {
        dispatchPrecondition(condition: .onQueue(queue))
        
        // Wait for data to be read.
        queueLock.lock()
        if (dataQueue.count == 0) {
            queueLock.wait(until: Date().addingTimeInterval(timeout))
        }
        queueLock.unlock()

        commandLock.lock()
        defer {
            commandLock.unlock()
        }
        
        if (dataQueue.count > 0) {
            let data = dataQueue.remove(at: 0)
            
            if (data[0] != sequence) {
                log.debug("Data Wrong Value.")
                throw PeripheralManagerError.incorrectResponse
            }
            return data
        }
        
        throw PeripheralManagerError.emptyValue
    }
}

//
//  PeripheralManager.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 10/10/21.
//

import CoreBluetooth
import Foundation
import os.log
import RileyLinkBLEKit

protocol MessageResult {
    
}

struct MessageSendFailure: MessageResult {
    var error: Error
}

struct MessageSendSuccess: MessageResult {
    
}

class PeripheralManager: NSObject {

    private let log = OSLog(category: "PeripheralManager")

    ///
    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            queue.sync {
                self.needsConfiguration = true
            }
        }
    }
    
    var dataQueue: [Data] = []
    var cmdQueue: [Data] = []
    
    let serviceUUID = CBUUID(string: "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F")
    let cmdCharacteristicUUID = CBUUID(string: "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F")
    let dataCharacteristicUUID = CBUUID(string: "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F")
    var cmdCharacteristic: CBCharacteristic?
    var dataCharacteristic: CBCharacteristic?
    
    /// The dispatch queue used to serialize operations on the peripheral
    let queue: DispatchQueue

    /// The condition used to signal command completion
    private let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    private(set) weak var central: CBCentralManager?
    
    // Confined to `queue`
    private var needsConfiguration = true
    
    weak var delegate: PeripheralManagerDelegate? {
        didSet {
            queue.sync {
                needsConfiguration = true
            }
        }
    }
    
    // Called from RileyLinkDeviceManager.managerQueue
    init(peripheral: CBPeripheral, centralManager: CBCentralManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.central = centralManager
        self.queue = queue

        super.init()

        peripheral.delegate = self

        assertConfiguration()
    }
    
    // TODO: Factor this out. We can communicate directly.
    public func runSession(withName name: String, _ block: @escaping (_ session: CommandSession) -> Void) {
        self.log.default("Scheduling session %{public}@", name)
//        queue.addOperation(self.configureAndRun({ [weak self] (manager) in
//            self?.log.default("======================== %{public}@ ===========================", name)
//            let bleFirmwareVersion = self?.bleFirmwareVersion
//            let radioFirmwareVersion = self?.radioFirmwareVersion
//
//            if bleFirmwareVersion == nil || radioFirmwareVersion == nil {
//                self?.log.error("Running session with incomplete configuration: bleFirmwareVersion %{public}@, radioFirmwareVersion: %{public}@", String(describing: bleFirmwareVersion), String(describing: radioFirmwareVersion))
//            }
//
//            block(CommandSession(manager: manager, responseType: bleFirmwareVersion?.responseType ?? .buffered, firmwareVersion: radioFirmwareVersion ?? .unknown))
//            self?.log.default("------------------------ %{public}@ ---------------------------", name)
//        }))
    }
}

extension PeripheralManager {
    enum CommandCondition {
        case notificationStateUpdate(characteristic: CBCharacteristic, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
    }
}

protocol PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)
    
    func peripheralManager(_ manager: PeripheralManager, didUpdateNotificationStateFor characteristic: CBCharacteristic)

    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager)

    func completeConfiguration(for manager: PeripheralManager) throws
}

extension PeripheralManager {
    func configureAndRun(_ block: @escaping (_ manager: PeripheralManager) -> Void) -> (() -> Void) {
        return {
            // TODO: Accessing self might be a race on initialization
            if !self.needsConfiguration && self.peripheral.services == nil {
                self.log.error("Configured peripheral has no services. Reconfiguring…")
            }
            
            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    try self.applyConfiguration()
                    self.log.default("Peripheral configuration completed")
                } catch let error {
                    self.log.error("Error applying peripheral configuration: %@", String(describing: error))
                    // Will retry
                }

                do {
                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.default("Delegate configuration completed")
                        self.needsConfiguration = false
                    } else {
                        self.log.error("No delegate set for configuration")
                    }
                } catch let error {
                    self.log.error("Error applying delegate configuration: %@", String(describing: error))
                    // Will retry
                }
            }

            block(self)
        }
    }

    func perform(_ block: @escaping (_ manager: PeripheralManager) -> Void) {
        queue.async(execute: configureAndRun(block))
    }

    private func assertConfiguration() {
        if peripheral.state == .connected {
            perform { (_) in
                // Intentionally empty to trigger configuration if necessary
            }
        }
    }

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
        try discoverServices([serviceUUID], timeout: discoveryTimeout)

        guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
            throw PeripheralManagerError.serviceNotFound
        }

        try discoverCharacteristics([cmdCharacteristicUUID, dataCharacteristicUUID], for: service, timeout: discoveryTimeout)

        guard let characteristic = service.characteristics?.itemWithUUID(cmdCharacteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        cmdCharacteristic = characteristic
        try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)

        guard let characteristic = service.characteristics?.itemWithUUID(dataCharacteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        dataCharacteristic = characteristic
        try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
    }
}

extension PeripheralManager {

    /// - Throws: PeripheralManagerError
    func sendHello(_ controllerId: Data) throws {
        guard let characteristic = cmdCharacteristic else {
            throw PeripheralManagerError.notReady
        }
        try writeValue(Data([PodCommand.HELLO.rawValue, 0x01, 0x04]) + controllerId, characteristic: characteristic, type: .withResponse, timeout: 5)
    }

    /// - Throws: PeripheralManagerError
    func sendCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws  {
        guard let characteristic = cmdCharacteristic else {
            throw PeripheralManagerError.notReady
        }
        try writeValue(Data([command.rawValue]), characteristic: characteristic, type: .withResponse, timeout: timeout)
    }
    
    /// - Throws: PeripheralManagerError
    func readCommandType(_ command: PodCommand, timeout: TimeInterval = 5) throws {
        guard let characteristic = cmdCharacteristic else {
            return
        }

        // If a command has not yet been received, wait for it.
        if (cmdQueue.count == 0) {
            try runCommand(timeout: timeout) {
                addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
            }
        }

        if (cmdQueue.count > 0) {
            let value = cmdQueue.remove(at: 0)
            
            if command.rawValue != value[0] {
                throw PeripheralManagerError.incorrectResponse
            }
            return
        }
        
        throw PeripheralManagerError.incorrectResponse
    }
    
    /// - Throws: PeripheralManagerError
    func sendData(_ value: Data, timeout: TimeInterval) throws {
        guard let characteristic = dataCharacteristic else {
            throw PeripheralManagerError.notReady
        }
        try? writeValue(value, characteristic: characteristic, type: .withResponse, timeout: timeout)
    }

    /// - Throws: PeripheralManagerError
    func readData(sequence: UInt8, timeout: TimeInterval) throws -> Data? {
        guard let characteristic = dataCharacteristic else {
            throw PeripheralManagerError.notReady
        }

        // If data hasn't been received yet, wait for it.
        if (dataQueue.count == 0) {
            try runCommand(timeout: timeout) {
                addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
            }
        }

        if (dataQueue.count > 0) {
            let data = dataQueue.remove(at: 0)
            if (data[0] != sequence) {
                throw PeripheralManagerError.incorrectResponse
            }
            return data
        }
        return nil
    }
    
    func sendMessage(_ message: MessagePacket, _ forEncryption: Bool = false) -> MessageResult {
        let group = DispatchGroup()
        var result: MessageResult = MessageSendSuccess()
        
        group.enter()
        reset()
        perform { [weak self] _ in
            do {
                guard let self = self else {
                    result = MessageSendFailure(error: PeripheralManagerError.notReady)
                    return
                }
                try self.sendCommandType(PodCommand.RTS, timeout: 5)
                try self.readCommandType(PodCommand.CTS, timeout: 5)

                let splitter = PayloadSplitter(payload: message.asData(forEncryption: forEncryption))
                let packets = splitter.splitInPackets()

                for packet in packets {
                    try self.sendData(packet.toData(), timeout: 5)
                    try self.peekForNack()
                }

                try self.readCommandType(PodCommand.SUCCESS, timeout: 5)
                group.leave()
            }
            catch {
                result = MessageSendFailure(error: error)
                group.leave()
            }
        }
        group.wait()
        reset()
        return result
    }
    
    func readMessage(_ readRTS: Bool = true) throws -> MessagePacket? {
        let group = DispatchGroup()
        var packet: MessagePacket?

        group.enter()
        reset()
        perform { [weak self] _ in
            do {
                guard let self = self else {
                    throw PeripheralManagerError.notReady
                }
                
                if (readRTS) {
                    try self.readCommandType(PodCommand.RTS)
                }
                
                try self.sendCommandType(PodCommand.CTS)

                var expected: UInt8 = 0
                let firstPacket = try self.readData(sequence: expected, timeout: 5)

                guard let firstPacket = firstPacket else {
                    return
                }

                let joiner = try PayloadJoiner(firstPacket: firstPacket)

                for i in 1...joiner.fullFragments {
                    expected += 1
                    guard let packet = try self.readData(sequence: expected, timeout: 5) else { return }
                    try joiner.accumulate(packet: packet)
                }
                if (joiner.oneExtraPacket) {
                    expected += 1
                    guard let packet = try self.readData(sequence: expected, timeout: 5) else { return }
                    try joiner.accumulate(packet: packet)
                }
                let fullPayload = try joiner.finalize()
                try  self.sendCommandType(PodCommand.SUCCESS)
                packet = try MessagePacket.parse(payload: fullPayload)
                group.leave()
            }
            catch {
                print(error)
                try? self?.sendCommandType(PodCommand.NACK)
                group.leave()
            }
        }
        group.wait()
        reset()
        return packet
    }

    func peekForNack() throws -> Void {
        if cmdQueue.contains(where: { cmd in
            return cmd[0] == PodCommand.NACK.rawValue
        }) {
            throw PeripheralManagerError.nack
        }
    }
}

extension PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, command: () -> Void) throws {
        // Prelude
//        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            throw PeripheralManagerError.notReady
        }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            throw PeripheralManagerError.timeout(commandConditions)
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
//        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }
    
    func reset() {
        commandConditions.removeAll()
        dataQueue.removeAll()
        cmdQueue.removeAll()
    }

    func discoverServices(_ serviceUUIDs: [CBUUID], timeout: TimeInterval) throws {
        let servicesToDiscover = peripheral.servicesToDiscover(from: serviceUUIDs)

        guard servicesToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverServices)

            peripheral.discoverServices(serviceUUIDs)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID], for service: CBService, timeout: TimeInterval) throws {
        let characteristicsToDiscover = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)

        guard characteristicsToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristic: characteristic, enabled: enabled))

            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

//            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }


    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        log.debug("writeValue")
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }
}

extension PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverServices = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristic: characteristic, enabled: characteristic.isNotifying) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
        delegate?.peripheralManager(self, didUpdateNotificationStateFor: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()
        
        log.debug("peripheral didWriteValueFor")
        
        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()
        
        log.debug("peripheral didUpdateValueFor")
        
        var notifyDelegate = false

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        } else {
            notifyDelegate = true // execute after the unlock
        }
        
        if (characteristic == dataCharacteristic && characteristic.value != nil) {
            // Adding to data queue
            dataQueue.append(characteristic.value!)
        }

        if (characteristic == cmdCharacteristic && characteristic.value != nil) {
            // Adding to cmd queue
            cmdQueue.append(characteristic.value!)
        }

        commandLock.unlock()

        if notifyDelegate {
            // If we weren't expecting this notification, pass it along to the delegate
            delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        delegate?.peripheralManagerDidUpdateName(self)
    }
}


extension PeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            assertConfiguration()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        switch peripheral.state {
        case .connected:
            assertConfiguration()
        default:
            break
        }
    }
}

extension PeripheralManager {
    
    public override var debugDescription: String {
        var items = [
            "## PeripheralManager",
            "peripheral: \(peripheral)"
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

extension CBPeripheral {
    func servicesToDiscover(from serviceUUIDs: [CBUUID]) -> [CBUUID] {
        let knownServiceUUIDs = services?.compactMap({ $0.uuid }) ?? []
        return serviceUUIDs.filter({ !knownServiceUUIDs.contains($0) })
    }

    func characteristicsToDiscover(from characteristicUUIDs: [CBUUID], for service: CBService) -> [CBUUID] {
        let knownCharacteristicUUIDs = service.characteristics?.compactMap({ $0.uuid }) ?? []
        return characteristicUUIDs.filter({ !knownCharacteristicUUIDs.contains($0) })
    }

//    func getCharacteristicWithUUID(_ uuid: MainServiceCharacteristicUUID, serviceUUID: RileyLinkServiceUUID = .main) -> CBCharacteristic? {
//        guard let service = services?.itemWithUUID(serviceUUID.cbUUID) else {
//            return nil
//        }
//
//        return service.characteristics?.itemWithUUID(uuid.cbUUID)
//    }
}


extension Collection where Element: CBAttribute {
    func itemWithUUID(_ uuid: CBUUID) -> Element? {
        for attribute in self {
            if attribute.uuid == uuid {
                return attribute
            }
        }

        return nil
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

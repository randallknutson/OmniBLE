//
//  MessageTransport.swift
//  OmniKit
//
//  Created by Pete Schwamb on 8/5/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation
import os.log

protocol MessageLogger: AnyObject {
    // Comms logging
    func didSend(_ message: Data)
    func didReceive(_ message: Data)
}

public struct MessageTransportState: Equatable, RawRepresentable {
    public typealias RawValue = [String: Any]

    public var ck: Data?
    public var noncePrefix: Data?
    public var msgSeq: Int // 8-bit Dash MessagePacket sequence #
    public var nonceSeq: Int
    public var messageNumber: Int // 4-bit Omnipod Message #
    
    init(ck: Data?, noncePrefix: Data?, msgSeq: Int = 0, nonceSeq: Int = 0, messageNumber: Int = 0) {
        self.ck = ck
        self.noncePrefix = noncePrefix
        self.msgSeq = msgSeq
        self.nonceSeq = nonceSeq
        self.messageNumber = messageNumber
    }
    
    // RawRepresentable
    public init?(rawValue: RawValue) {
        guard
            let ckString = rawValue["ck"] as? String,
            let noncePrefixString = rawValue["noncePrefix"] as? String,
            let msgSeq = rawValue["msgSeq"] as? Int,
            let nonceSeq = rawValue["nonceSeq"] as? Int,
            let messageNumber = rawValue["messageNumber"] as? Int
            else {
                return nil
        }
        self.ck = Data(hex: ckString)
        self.noncePrefix = Data(hex: noncePrefixString)
        self.msgSeq = msgSeq
        self.nonceSeq = nonceSeq
        self.messageNumber = messageNumber
    }
    
    public var rawValue: RawValue {
        return [
            "ck": ck?.hexadecimalString ?? "",
            "noncePrefix": noncePrefix?.hexadecimalString ?? "",
            "msgSeq": msgSeq,
            "nonceSeq": nonceSeq,
            "messageNumber": messageNumber
        ]
    }

}

extension MessageTransportState: CustomDebugStringConvertible {
    public var debugDescription: String {
        return [
            "## MessageTransportState",
            "ck: " + (ck != nil ? ck!.hexadecimalString : "nil"),
            "noncePrefix: " + (noncePrefix != nil ? noncePrefix!.hexadecimalString : "nil"),
            "msgSeq: \(msgSeq)",
            "nonceSeq: \(nonceSeq)",
            "messageNumber: \(messageNumber)",
        ].joined(separator: "\n")
    }
}

protocol MessageTransportDelegate: AnyObject {
    func messageTransport(_ messageTransport: MessageTransport, didUpdate state: MessageTransportState)
}

protocol MessageTransport {
    var delegate: MessageTransportDelegate? { get set }

    var messageNumber: Int { get }

    func sendMessage(_ message: Message) throws -> Message

    /// Asserts that the caller is currently on the session's queue
    func assertOnSessionQueue()
}

class PodMessageTransport: MessageTransport {
    private let COMMAND_PREFIX = "S0.0="
    private let COMMAND_SUFFIX = ",G0.0"
    private let RESPONSE_PREFIX = "0.0="
    
    private let manager: PeripheralManager
    
    private var nonce: Nonce?
    private var enDecrypt: EnDecrypt?

    private let log = OSLog(category: "PodMessageTransport")
    
    private var state: MessageTransportState {
        didSet {
            self.delegate?.messageTransport(self, didUpdate: state)
        }
    }
    
    private(set) var ck: Data? {
        get {
            return state.ck
        }
        set {
            state.ck = newValue
        }
    }
    
    private(set) var noncePrefix: Data? {
        get {
            return state.noncePrefix
        }
        set {
            state.noncePrefix = newValue
        }
    }
    
    private(set) var msgSeq: Int {
        get {
            return state.msgSeq
        }
        set {
            state.msgSeq = newValue
        }
    }
    
    private(set) var nonceSeq: Int {
        get {
            return state.nonceSeq
        }
        set {
            state.nonceSeq = newValue
        }
    }
    
    private(set) var messageNumber: Int {
        get {
            return state.messageNumber
        }
        set {
            state.messageNumber = newValue
        }
    }

    private let address: UInt32
    private let fakeSendMessage = false // whether to fake sending pod messages
    
    weak var messageLogger: MessageLogger?
    weak var delegate: MessageTransportDelegate?

    init(manager: PeripheralManager, address: UInt32, state: MessageTransportState) {
        self.manager = manager
        self.address = address
        self.state = state
        
        guard let noncePrefix = self.noncePrefix, let ck = self.ck else { return }
        self.nonce = Nonce(prefix: noncePrefix)
        self.enDecrypt = EnDecrypt(nonce: self.nonce!, ck: ck)
    }
    
    private func incrementMsgSeq(_ count: Int = 1) {
        msgSeq = ((msgSeq) + count) & 0xff // msgSeq is the 8-bit Dash MessagePacket sequence #
    }

    private func incrementNonceSeq(_ count: Int = 1) {
        nonceSeq = nonceSeq + count
    }

    private func incrementMessageNumber(_ count: Int = 1) {
        messageNumber = ((messageNumber) + count) & 0b1111 // messageNumber is the 4-bit Omnipod Message #
    }

    /// Sends the given pod message over the encrypted Dash transport and returns the pod's response
    func sendMessage(_ message: Message) throws -> Message {

        messageNumber = message.sequenceNum // reset our Omnipod message # to given value
        incrementMessageNumber() // bump to match expected Omnipod message # in response

        let dataToSend = message.encoded()
        log.default("Send(Hex): %@", dataToSend.hexadecimalString)
        messageLogger?.didSend(dataToSend)

        if fakeSendMessage {
            // temporary code to fake basic pi simulator message exchange
            let messageBlockType: MessageBlockType = message.messageBlocks[0].blockType
            let responseData: Data

            switch messageBlockType {
            case .assignAddress:
                responseData = Data(hexadecimalString: "FFFFFFFF00000115040A00010300040208146CC1000954D400FFFFFFFF800F")!
                break
            case .setupPod:
                responseData = Data(hexadecimalString: "FFFFFFFF0000011B13881008340A50040A00010300040308146CC1000954D40242000100A2")!
                break
            case .versionResponse, .podInfoResponse, .errorResponse, .statusResponse:
                log.error("Trying to send a response type message!: %@", String(describing: message))
                throw PodCommsError.invalidData
            case .basalScheduleExtra, .tempBasalExtra, .bolusExtra:
                log.error("Trying to send an insulin extra sub-message type!: %@", String(describing: message))
                throw PodCommsError.invalidData
            default:
                // A random general status response (assumes type 0 for a getStatus command)
                responseData = Data(hexadecimalString: "FFFFFFFF00001D1800A02800000463FF0244")!
                break
            }

            let response = try Message(encodedData: responseData)
            log.default("Recv(Hex): %@", responseData.hexadecimalString)
            messageLogger?.didReceive(responseData)
            incrementMessageNumber()
            return response
        }

        let sendMessage = try getCmdMessage(cmd: message)

        let writeResult = try manager.sendMessage(sendMessage)
        guard ((writeResult as? MessageSendSuccess) != nil) else {
            throw BluetoothErrors.MessageIOException("Could not write $msgType: \(writeResult)")
        }

        let response = try readAndAckResponse()
        incrementMessageNumber() // bump the 4-bit Omnipod Message number

        return response
    }
    
    private func getCmdMessage(cmd: Message) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.noPodAvailable }

        incrementMsgSeq()

        let wrapped = StringLengthPrefixEncoding.formatKeys(
            keys: [COMMAND_PREFIX, COMMAND_SUFFIX],
            payloads: [cmd.encoded(), Data()]
        )

        log.debug("Sending command: %@", wrapped.hexadecimalString)

        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            destination: self.address,
            payload: wrapped,
            sequenceNumber: UInt8(msgSeq),
            eqos: 1
        )

        incrementNonceSeq()
        return try enDecrypt.encrypt(msg, nonceSeq)
    }
    
    func readAndAckResponse() throws -> Message {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.noPodAvailable }

        let readResponse = try manager.readMessage()
        guard let readMessage = readResponse else {
            throw BluetoothErrors.MessageIOException("Could not read response")
        }

        incrementNonceSeq()
        let decrypted = try enDecrypt.decrypt(readMessage, nonceSeq)

        log.debug("Received response: %@", decrypted.payload.hexadecimalString)

        let response = try parseResponse(decrypted: decrypted)

        /*if (!responseType.isInstance(response)) {
            if (response is AlarmStatusResponse) {
                throw PodAlarmException(response)
            }
            if (response is NakResponse) {
                throw NakResponseException(response)
            }
            throw IllegalResponseException(responseType, response)
        }
         */

        incrementMsgSeq()
        incrementNonceSeq()
        let ack = try getAck(response: decrypted)
        log.debug("Sending ACK: %@ in packet $ack", ack.payload.hexadecimalString)
        let ackResult = try manager.sendMessage(ack)
        guard ((ackResult as? MessageSendSuccess) != nil) else {
            throw BluetoothErrors.MessageIOException("Could not write $msgType: \(ackResult)")
        }

        // verify that the Omnipod message # matches the expected value
        guard response.sequenceNum == messageNumber else {
            throw MessageError.invalidSequence
        }

        return response
    }
    
    private func parseResponse(decrypted: MessagePacket) throws -> Message {

        let data = try StringLengthPrefixEncoding.parseKeys([RESPONSE_PREFIX], decrypted.payload)[0]
        log.info("Received decrypted response: %@ in packet: %@", data.hexadecimalString, decrypted.payload.hexadecimalString)

        let response = try Message.init(encodedData: data)

        log.default("Recv(Hex): %@", data.hexadecimalString)
        messageLogger?.didReceive(data)

        return response
    }
    
    private func getAck(response: MessagePacket) throws -> MessagePacket {
        guard let enDecrypt = self.enDecrypt else { throw PodCommsError.noPodAvailable }

        let ackNumber = (UInt(response.sequenceNumber) + 1) & 0xff
        let msg = MessagePacket(
            type: MessageType.ENCRYPTED,
            source: response.destination.toUInt32(),
            destination: response.source.toUInt32(),
            payload: Data(),
            sequenceNumber: UInt8(msgSeq),
            ack: true,
            ackNumber: UInt8(ackNumber),
            eqos: 0
        )
        return try enDecrypt.encrypt(msg, nonceSeq)
    }
    
    func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }
}

extension PodMessageTransport: CustomDebugStringConvertible {
    public var debugDescription: String {
        return [
            "## PodMessageTransport",
            "ck: " + (ck != nil ? ck!.hexadecimalString : "nil"),
            "noncePrefix: " + (noncePrefix != nil ? noncePrefix!.hexadecimalString : "nil"),
            "msgSeq: \(msgSeq)",
            "nonceSeq: \(nonceSeq)",
            "messageNumber: \(messageNumber)",
        ].joined(separator: "\n")
    }
}

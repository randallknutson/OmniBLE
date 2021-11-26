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
    public var nonce: Data?
    public var msgSeq: Int
    
    init(ck: Data?, nonce: Data?, msgSeq: Int = 0) {
        self.ck = ck
        self.nonce = nonce
        self.msgSeq = msgSeq
    }
    
    // RawRepresentable
    public init?(rawValue: RawValue) {
        guard
            let ckString = rawValue["ck"] as? String,
            let nonceString = rawValue["nonce"] as? String,
            let msgSeq = rawValue["msgSeq"] as? Int
            else {
                return nil
        }
        self.ck = Data(hex: ckString)
        self.nonce = Data(hex: nonceString)
        self.msgSeq = msgSeq
    }
    
    public var rawValue: RawValue {
        return [
            "ck": ck?.hexadecimalString ?? "",
            "nonce": nonce?.hexadecimalString ?? "",
            "msgSeq": msgSeq
        ]
    }

}

protocol MessageTransportDelegate: AnyObject {
    func messageTransport(_ messageTransport: MessageTransport, didUpdate state: MessageTransportState)
}

protocol MessageTransport {
    var delegate: MessageTransportDelegate? { get set }

    var msgSeq: Int { get }

    func sendMessage(_ message: Message) throws -> Message

    /// Asserts that the caller is currently on the session's queue
    func assertOnSessionQueue()
}

class PodMessageTransport: MessageTransport {
    
    private let manager: PeripheralManager
    
    private var nonce: Nonce?
    private var endecrypt: EnDecrypt?

    
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
            return state.nonce
        }
        set {
            state.nonce = newValue
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
    
    private let address: UInt32
    private let fakeSendMessage = false // whether to fake sending pod messages
    
    weak var messageLogger: MessageLogger?
    weak var delegate: MessageTransportDelegate?

    init(manager: PeripheralManager, address: UInt32 = 0xffffffff,  state: MessageTransportState) {
        self.manager = manager
        self.address = address
        self.state = state
        
        guard let noncePrefix = self.noncePrefix, let ck = self.ck else { return }
        self.nonce = Nonce(prefix: noncePrefix, sqn: 0)
        self.endecrypt = EnDecrypt(nonce: self.nonce!, ck: ck)
    }
    
    private func incrementMsgSeq(_ count: Int = 1) {
        msgSeq = ((msgSeq) + count) & 0b1111
    }

    /// Sends the given pod message over the encrypted Dash transport and returns the pod's response
    func sendMessage(_ message: Message) throws -> Message {
        let response: Message

        let dataToSend = message.encoded()
        log.default("Send(Hex): %@", dataToSend.hexadecimalString)
        messageLogger?.didSend(dataToSend)

        if fakeSendMessage {
            // temporary code to fake basic pi simulator message exchange
            let messageBlockType: MessageBlockType = message.messageBlocks[0].blockType
            switch messageBlockType {
            case .assignAddress:
                response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF00000115040A00010300040208146CC1000954D400FFFFFFFF800F")!)
                break
            case .setupPod:
                response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF0000011B13881008340A50040A00010300040308146CC1000954D40242000100A2")!)
                break
            case .versionResponse, .podInfoResponse, .errorResponse, .statusResponse:
                log.error("Trying to send a response type message!: %@", String(describing: message))
                throw PodCommsError.invalidData
            case .basalScheduleExtra, .tempBasalExtra, .bolusExtra:
                log.error("Trying to send an insulin extra sub-message type!: %@", String(describing: message))
                throw PodCommsError.invalidData
            default:
                // A random general status response (assumes type 0 for a getStatus command)
                response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF00001D1800A02800000463FF0244")!)
                break
            }
        } else {
            guard let endecrypt = self.endecrypt else { throw PodCommsError.noPodAvailable }

            var sendMessage = MessagePacket(type: .ENCRYPTED, address: message.address, payload: message.encoded(), sequenceNumber: UInt8(msgSeq), tfs: true)
            sendMessage = try endecrypt.encrypt(sendMessage)

            let writeResult = try manager.sendMessage(sendMessage)
            guard ((writeResult as? MessageSendSuccess) != nil) else {
                throw BluetoothErrors.MessageIOException("Could not write $msgType: \(writeResult)")
            }

            let readResponse = try manager.readMessage()
            guard var readMessage = readResponse else {
                throw BluetoothErrors.MessageIOException("Could not read response")
            }

            readMessage = try endecrypt.decrypt(readMessage)

            return try Message.init(encodedData: readMessage.payload)
        }

        let responseData = response.encoded()
        log.default("Recv(Hex): %@", responseData.hexadecimalString)
        messageLogger?.didReceive(responseData)

        return response
    }

    func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }
}

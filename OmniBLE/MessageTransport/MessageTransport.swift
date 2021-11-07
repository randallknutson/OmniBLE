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

    public var ltk: Data
    public var messageNumber: Int
    
    init(ltk: Data, messageNumber: Int) {
        self.ltk = ltk
        self.messageNumber = messageNumber
    }
    
    // RawRepresentable
    public init?(rawValue: RawValue) {
        guard
            let ltkString = rawValue["ltk"] as? String,
            let messageNumber = rawValue["messageNumber"] as? Int
            else {
                return nil
        }
        self.ltk = Data(hex: ltkString)
        self.messageNumber = messageNumber
    }
    
    public var rawValue: RawValue {
        return [
            "ltk": ltk.hexadecimalString,
            "messageNumber": messageNumber
        ]
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
    
    private let manager: PeripheralManager
    
    private let log = OSLog(category: "PodMessageTransport")
    
    private var state: MessageTransportState {
        didSet {
            self.delegate?.messageTransport(self, didUpdate: state)
        }
    }
    
    private(set) var ltk: Data {
        get {
            return state.ltk
        }
        set {
            state.ltk = newValue
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
    
    weak var messageLogger: MessageLogger?
    weak var delegate: MessageTransportDelegate?

    init(manager: PeripheralManager, address: UInt32 = 0xffffffff,  state: MessageTransportState) {
        self.manager = manager
        self.address = address
        self.state = state
    }
    
    private func incrementMessageNumber(_ count: Int = 1) {
        messageNumber = (messageNumber + count) & 0b1111
    }

    /// Sends the given pod message over the encrypted Dash transport and returns the pod's response
    /// XXX - need to figure out if Dash sends Messages or MessageBlocks over the encrypted connection,
    /// possibly it might make sense to have a differnt definition for a Message for Dash without
    /// the 32 bit address, the B9 byte (with its 4-bit mesage sequence #), the BLen byte, and the CRC16
    func sendMessage(_ message: Message) throws -> Message {
        let messageBlockType: MessageBlockType = message.messageBlocks[0].blockType
        let response: Message

        // XXX placeholder code returning the fixed responses from the pi pod simulator
        switch messageBlockType {
        case .assignAddress:
            response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF00000115040A00010300040208146CC1000954D400FFFFFFFF0000")!)
            break
        case .setupPod:
            response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF0000011B13881008340A50040A00010300040308146CC1000954D4024200010000")!)
            break
        case .versionResponse, .podInfoResponse, .errorResponse, .statusResponse:
            log.error("Trying to send a response type message!: %@", String(describing: message))
            throw PodCommsError.invalidData
        case .basalScheduleExtra, .tempBasalExtra, .bolusExtra:
            log.error("Trying to send an insulin extra sub-message type!: %@", String(describing: message))
            throw PodCommsError.invalidData
        default:
            // A random general status response (assumes type 0 for a getStatus command)
            response = try Message(encodedData: Data(hexadecimalString: "FFFFFFFF00001D1800A02800000463FF0000")!)
            break
        }

        return response
    }

    func assertOnSessionQueue() {
        dispatchPrecondition(condition: .onQueue(manager.queue))
    }
}

//
//  PodComms.swift
//  OmnipodKit
//
//  Created by Pete Schwamb on 10/7/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation
import LoopKit
import os.log

protocol PodCommsDelegate: AnyObject {
    func podComms(_ podComms: PodComms, didChange podState: PodState)
}

public class PodComms: CustomDebugStringConvertible {
    
    var manager: PeripheralManager?
    
//    private let configuredDevices: Locked<Set<Omnipod>> = Locked(Set())
    
    weak var delegate: PodCommsDelegate?
    
    weak var messageLogger: MessageLogger?

    public let log = OSLog(category: "PodComms")

    private var startingPacketNumber = 0

    // Only valid to access on the session serial queue
    private var podState: PodState? {
        didSet {
            if let newValue = podState, newValue != oldValue {
                delegate?.podComms(self, didChange: newValue)
            }
        }
    }
    
    init(podState: PodState?) {
        self.podState = podState
        self.delegate = nil
        self.messageLogger = nil
    }

    private func pairPod(_ ids: Ids) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }
        try manager.sendHello(ids.myId.address)
        let address = ids.podId.toUInt32()

        let ltkExchanger = LTKExchanger(manager: manager, ids: ids)
        let response = try ltkExchanger.negotiateLTK()

        let packetNumber, messageNumber: Int
        let ltk: Data
        if let podState = self.podState {
            ltk = podState.messageTransportState.ltk
            packetNumber = podState.messageTransportState.packetNumber
            messageNumber = podState.messageTransportState.messageNumber
        } else {
            ltk = response.ltk
            packetNumber =  self.startingPacketNumber
            messageNumber = Int(response.msgSeq)
        }

        log.debug("Attempting pairing with address %{public}@ using packet #%d", String(format: "%04X", address), packetNumber)
        let messageTransportState = MessageTransportState(ltk: ltk, packetNumber: packetNumber, messageNumber: messageNumber)
        let transport = PodMessageTransport(manager: manager, address: 0xffffffff, ackAddress: address, state: messageTransportState)
        transport.messageLogger = messageLogger
        
        if self.podState == nil {
            log.default("Creating PodState for address %{public}@ [lot %u tid %u], packet #%d, message #%d", String(format: "%04X", response.address), 1, 1, transport.packetNumber, transport.messageNumber)
            self.podState = PodState(
                address: response.address,
                ltk: response.ltk,
                packetNumber: transport.packetNumber,
                messageNumber: transport.messageNumber,
                lotNo: 1, // TODO: Fixme
                lotSeq: 1 // TODO: Fixme
            )
        }

        log.info("Pairing is now complete")
        self.podState?.setupProgress = .podPaired
    }
    
//    private func setupPod(podState: PodState, timeZone: TimeZone) throws {
//        guard let manager = manager else { throw PodCommsError.noPodAvailable }
//        let transport = PodMessageTransport(manager: manager, address: 0xffffffff, ackAddress: podState.address, state: podState.messageTransportState)
//        transport.messageLogger = messageLogger
//
//        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
//        let setupPod = SetupPodCommand(address: podState.address, dateComponents: dateComponents, lot: podState.lot, tid: podState.tid)
//
//        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: transport.messageNumber)
//
//        let versionResponse: VersionResponse
//        do {
//            versionResponse = try sendPairMessage(address: podState.address, transport: transport, message: message)
//        } catch let error {
//            if case PodCommsError.podAckedInsteadOfReturningResponse = error {
//                log.default("SetupPod acked instead of returning response.")
//                if self.podState?.setupProgress.isPaired == false {
//                    log.default("Moving pod to paired state.")
//                    self.podState?.setupProgress = .podPaired
//                }
//                return
//            }
//            log.error("SetupPod returns error %{public}@", String(describing: error))
//            throw error
//        }
//
//        guard versionResponse.isSetupPodVersionResponse else {
//            log.error("SetupPod unexpected VersionResponse type: %{public}@", String(describing: versionResponse))
//            throw PodCommsError.invalidData
//        }
//    }
    
    func pairAndSetupPod(
        address: UInt32,
        timeZone: TimeZone,
        messageLogger: MessageLogger?,
        _ block: @escaping (_ result: SessionRunResult) -> Void
    ) {
        guard let manager = manager else {
            block(.failure(PodCommsError.noPodPaired))
            return
        }

        manager.perform { [weak self] _ in
            do {
                guard let self = self else { fatalError() }

                if self.podState == nil {
                    let ids = Ids(podState: self.podState)
                    try self.pairPod(ids)
                }
                
                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

//                if self.podState!.setupProgress.isPaired == false {
//                    try self.setupPod(podState: self.podState!, timeZone: timeZone)
//                }

                guard self.podState!.setupProgress.isPaired else {
                    self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                    throw PodCommsError.invalidData
                }
                self.startingPacketNumber = 0

                // Run a session now for any post-pairing commands
                let transport = PodMessageTransport(manager: manager, address: self.podState!.address, state: self.podState!.messageTransportState)
                transport.messageLogger = self.messageLogger
                let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)

                block(.success(session: podSession))
            } catch let error as PodCommsError {
                block(.failure(error))
            } catch {
                block(.failure(PodCommsError.commsError(error: error)))
            }
        }
    }
    
    enum SessionRunResult {
        case success(session: PodCommsSession)
        case failure(PodCommsError)
    }
    
    func runSession(withName name: String, _ block: @escaping (_ result: SessionRunResult) -> Void) {

        guard let manager = manager else {
            block(.failure(PodCommsError.noPodAvailable))
            return
        }

//        manager.runSession(withName: name) { () in
//            guard self.podState != nil else {
//                block(.failure(PodCommsError.noPodPaired))
//                return
//            }
//
//            self.configureDevice(device, with: commandSession)
//            let transport = PodMessageTransport(manager: manager, address: self.podState!.address, state: self.podState!.messageTransportState)
//            transport.messageLogger = self.messageLogger
//            let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)
//            block(.success(session: podSession))
//        }
    }

    // MARK: - CustomDebugStringConvertible
    
    public var debugDescription: String {
        return [
            "## PodComms",
            "podState: \(String(reflecting: podState))",
            "delegate: \(String(describing: delegate != nil))",
            ""
        ].joined(separator: "\n")
    }

}

extension PodComms: PodCommsSessionDelegate {
    public func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        podCommsSession.assertOnSessionQueue()
        self.podState = state
    }
}

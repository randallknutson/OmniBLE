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

    // Handles all the common work to send and verify the version response for the two pairing pod commands, AssignAddress and SetupPod.
    private func sendPairMessage(transport: PodMessageTransport, message: Message) throws -> VersionResponse {

        let podMessageResponse = try transport.sendMessage(message)

        if let fault = podMessageResponse.fault {
            log.error("sendPairMessage pod fault: %{public}@", String(describing: fault))
            if let podState = self.podState, podState.fault == nil {
                self.podState!.fault = fault
            }
            throw PodCommsError.podFault(fault: fault)
        }

        guard let versionResponse = podMessageResponse.messageBlocks[0] as? VersionResponse else {
            log.error("sendPairMessage unexpected response: %{public}@", String(describing: podMessageResponse))
            let responseType = podMessageResponse.messageBlocks[0].blockType
            throw PodCommsError.unexpectedResponse(response: responseType)
        }

        return versionResponse
    }

    private func pairPod(ids: Ids) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }
        try manager.sendHello(ids.myId.address)
        let address = ids.podId.toUInt32()

        let ltkExchanger = LTKExchanger(manager: manager, ids: ids)
        let response = try ltkExchanger.negotiateLTK()

        log.info("LTK and encrypted transport now ready")

        // If we get here, we have the LTK all set up and we should be able use encrypted pod messages
        let messageNumber: Int
        let ltk: Data
        if let podState = self.podState {
            ltk = podState.messageTransportState.ltk
            messageNumber = podState.messageTransportState.messageNumber
        } else {
            ltk = response.ltk
            messageNumber = Int(response.msgSeq)
        }

        log.debug("Attempting encrypted pod assign address command using address %{public}@", String(format: "%04X", address))
        let messageTransportState = MessageTransportState(ltk: ltk, messageNumber: messageNumber)
        let transport = PodMessageTransport(manager: manager, address: 0xffffffff, state: messageTransportState)
        transport.messageLogger = messageLogger

        // Create the Assign Address command message
        // XXX - use the ids.podId here or use the generated 0x1F0xxxxx address?
        let assignAddress = AssignAddressCommand(address: address)
        let message = Message(type: .CLEAR, address: 0xffffffff, messageBlocks: [assignAddress], sequenceNumber: UInt8(transport.messageNumber))

        let versionResponse = try sendPairMessage(transport: transport, message: message)

        if self.podState == nil {
            log.default("Creating PodState for versionResponse %{public}@", String(describing: versionResponse))
            self.podState = PodState(
                address: response.address, // YYY is this correct or use config.address?
                ltk: response.ltk,
                messageNumber: transport.messageNumber,
                lotNo: UInt64(versionResponse.lot),
                lotSeq: versionResponse.tid
            )
            // podState setupProgress state should be addressAssigned
        }

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

    }
    
    private func setupPod(podState: PodState, timeZone: TimeZone) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }
        let transport = PodMessageTransport(manager: manager, address: 0xffffffff, state: podState.messageTransportState)
        transport.messageLogger = messageLogger

        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        let setupPod = SetupPodCommand(address: podState.address, dateComponents: dateComponents, lot: UInt32(podState.lotNo), tid: podState.lotSeq)

        let message = Message(type: .CLEAR, address: 0xffffffff, messageBlocks: [setupPod], sequenceNumber: UInt8(transport.messageNumber))

        let versionResponse = try sendPairMessage(transport: transport, message: message)

        // Verify that the fundemental pod constants returned match the expected constant values in the Pod struct.
        // To actually be able to handle different fundemental values in Loop things would need to be reworked to save
        // these values in some persistent PodState and then make sure that everything properly works using these values.
        var errorStrings: [String] = []
        if let pulseSize = versionResponse.pulseSize, pulseSize != Pod.pulseSize  {
            errorStrings.append(String(format: "Pod reported pulse size of %.3fU different than expected %.3fU", pulseSize, Pod.pulseSize))
        }
        if let secondsPerBolusPulse = versionResponse.secondsPerBolusPulse, secondsPerBolusPulse != Pod.secondsPerBolusPulse  {
            errorStrings.append(String(format: "Pod reported seconds per pulse rate of %.1f different than expected %.1f", secondsPerBolusPulse, Pod.secondsPerBolusPulse))
        }
        if let secondsPerPrimePulse = versionResponse.secondsPerPrimePulse, secondsPerPrimePulse != Pod.secondsPerPrimePulse  {
            errorStrings.append(String(format: "Pod reported seconds per prime pulse rate of %.1f different than expected %.1f", secondsPerPrimePulse, Pod.secondsPerPrimePulse))
        }
        if let primeUnits = versionResponse.primeUnits, primeUnits != Pod.primeUnits {
            errorStrings.append(String(format: "Pod reported prime bolus of %.2fU different than expected %.2fU", primeUnits, Pod.primeUnits))
        }
        if let cannulaInsertionUnits = versionResponse.cannulaInsertionUnits, Pod.cannulaInsertionUnits != cannulaInsertionUnits {
            errorStrings.append(String(format: "Pod reported cannula insertion bolus of %.2fU different than expected %.2fU", cannulaInsertionUnits, Pod.cannulaInsertionUnits))
        }
        if let serviceDuration = versionResponse.serviceDuration {
            if serviceDuration < Pod.serviceDuration {
                errorStrings.append(String(format: "Pod reported service duration of %.0f hours shorter than expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours))
            } else if serviceDuration > Pod.serviceDuration {
                log.info("Pod reported service duration of %.0f hours limited to expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours)
            }
        }

        let errMess = errorStrings.joined(separator: ".\n")
        if errMess.isEmpty == false {
            log.error("%@", errMess)
            self.podState?.setupProgress = .podIncompatible
            throw PodCommsError.podIncompatible(str: errMess)
        }

        if versionResponse.podProgressStatus == .pairingCompleted && self.podState?.setupProgress.isPaired == false {
            log.info("Version Response %{public}@ indicates pod pairing is now complete", String(describing: versionResponse))
            self.podState?.setupProgress = .podPaired
        }
    }
    
    func pairAndSetupPod(
        address: UInt32,
        timeZone: TimeZone,
        messageLogger: MessageLogger?,
        _ block: @escaping (_ result: SessionRunResult) -> Void
    ) {
        guard let manager = manager else {
            // no available Dash pump to communicate with
            block(.failure(PodCommsError.noResponse))
            return
        }

        manager.perform { [weak self] _ in
            do {
                guard let self = self else { fatalError() }

                if self.podState == nil {
                    let ids = Ids(podState: self.podState)
                    try self.pairPod(ids: ids)
                }
                
                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                if self.podState!.setupProgress.isPaired == false {
                    try self.setupPod(podState: self.podState!, timeZone: timeZone)
                }

                guard self.podState!.setupProgress.isPaired else {
                    self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                    throw PodCommsError.invalidData
                }

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
    
    // Use to serialize a set of Pod Commands for a given session
    // XXX need to figure out how much of this is actually really needed
    func runSession(withName name: String, _ block: @escaping (_ result: SessionRunResult) -> Void) {

        guard let manager = manager else {
            block(.failure(PodCommsError.noPodAvailable))
            return
        }

        /*
        manager.runSession(withName: name) { () in
            guard self.podState != nil else {
                block(.failure(PodCommsError.noPodPaired))
                return
            }

            // self.configureDevice(device, with: commandSession) no RL to configure
            let transport = PodMessageTransport(manager: manager, address: self.podState!.address, state: self.podState!.messageTransportState)
            transport.messageLogger = self.messageLogger
            let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)
            block(.success(session: podSession))
        }
         */
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

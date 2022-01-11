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
    private let lotNo: UInt64?
    private let lotSeq: UInt32?

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
    
    public var isPaired: Bool {
        get {
            return self.podState?.ltk != nil && (self.podState?.ltk.count ?? 0) > 0
        }
    }
    
    init(podState: PodState?, lotNo: UInt64?, lotSeq: UInt32?) {
        self.podState = podState
        self.delegate = nil
        self.messageLogger = nil
        self.lotNo = lotNo
        self.lotSeq = lotSeq
    }

    // Handles all the common work to send and verify the version response for the two pairing pod commands, AssignAddress and SetupPod.
    private func sendPairMessage(transport: PodMessageTransport, message: Message) throws -> VersionResponse {

        defer {
            if self.podState != nil {
                log.debug("sendPairMessage saving current message transport state %@", String(reflecting: transport))
                self.podState!.messageTransportState = MessageTransportState(ck: transport.ck, noncePrefix: transport.noncePrefix, msgSeq: transport.msgSeq, nonceSeq: transport.nonceSeq, messageNumber: transport.messageNumber)
            }
        }

        log.debug("sendPairMessage: attempting to use PodMessageTransport %@ to send message %@", String(reflecting: transport), String(reflecting: message))
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

        log.debug("sendPairMessage: returning versionResponse %@", String(describing: versionResponse))
        return versionResponse
    }

    public func pairPod(ids: Ids) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }
        let address = ids.podId.toUInt32()

        let ltkExchanger = LTKExchanger(manager: manager, ids: ids)
        let response = try ltkExchanger.negotiateLTK()
        let ltk = response.ltk

        guard address == response.address else {
            log.debug("podPair: address %{public} doesn't match response value?!: %@", String(format: "%04X", address), String(describing: response))
            throw PodCommsError.invalidAddress(address: response.address, expectedAddress: address)
        }

        // XXX need to rework things so that we don't have to create this temp PodState with the LTK to set up the encrypted transport
        if self.podState == nil {
            log.debug("pairPod: creating a temp podState for LTK using response %@", String(describing: response))
            self.podState = PodState(
                address: response.address,
                ltk: ltk,
                firmwareVersion: "",
                bleFirmwareVersion: "",
                lotNo: 0,
                lotSeq: 0,
                productId: dashProductId
            )
        }

        log.info("Establish an Eap Session")
        try self.establishSession(msgSeq: Int(response.msgSeq))

        log.info("LTK and encrypted transport now ready")
        log.debug("pairPod: LTK and encrypted transport now ready, podState messageTransportState: %@", String(reflecting: podState!.messageTransportState))

        // If we get here, we have the LTK all set up and we should be able use encrypted pod messages
        let transport = PodMessageTransport(manager: manager, address: response.address, state: podState!.messageTransportState)
        transport.messageLogger = messageLogger

        // For Dash this command is vestigal and doesn't actually assign the address (ID)
        // any more as this is done earlier when the LTK is setup. But this Omnipod comamnd is still
        // needed albiet using 0xffffffff for the address while the Eros sets the 0x1f0xxxxx ID.
        let assignAddress = AssignAddressCommand(address: 0xffffffff)
        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: transport.messageNumber)

        let versionResponse = try sendPairMessage(transport: transport, message: message)

        // Information checks comparing the version response values to the earlier values

        // N.B., The pod simulator always returns 0xFFFFFFFF regardless of the address used in the AssignAddressCommand command
        if versionResponse.address != 0xFFFFFFFF && versionResponse.address != response.address {
            log.debug("pairPod: versionResponse.address 0x%08X (%d) doesn't match response.address of 0x%08x (%d)", versionResponse.address, versionResponse.address, response.address, response.address)
        }
        if let lotSeq = self.lotSeq {
            if versionResponse.tid != lotSeq {
                log.debug("pairPod: versionResponse.tid 0x%08X doesn't match lotSeq of 0x%08X (%u)", versionResponse.tid, lotSeq, lotSeq)
            }
        } else {
            log.debug("pairPod: got versionResponse.tid of 0x%08X (%u) with no previous lotSeq", versionResponse.tid, versionResponse.tid)
        }
        if let lotNo = self.lotNo {
            if versionResponse.lot != lotNo {
                log.debug("pairPod: versionResponse.lot 0x%08X doesn't match lotNo of 0x%08X (%u)", versionResponse.lot, lotNo, lotNo)
            }
        } else {
            log.debug("pairPod: got versionResponse.lot of 0x%08X (%u) with no previous lotNo", versionResponse.lot, versionResponse.lot)
        }

        // Now create the real PodState using the versionResponse info
        log.debug("pairPod: creating PodState for versionResponse %{public}@ for %{public}@", String(describing: versionResponse), String(describing: self))
        self.podState = PodState(
            address: response.address,
            ltk: ltk,
            firmwareVersion: String(describing: versionResponse.firmwareVersion),
            bleFirmwareVersion: String(describing: versionResponse.iFirmwareVersion),
            lotNo: UInt64(versionResponse.lot), // XXX get 5-byte lotNo from attributes or use this 4-byte lotNo in versionResponse?
            lotSeq: versionResponse.tid, // XXX get from attributes?
            productId: versionResponse.productId,
            messageTransportState: podState!.messageTransportState
        )
        // podState setupProgress state should be addressAssigned

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

        log.debug("pairPod: self.PodState messageTransportState now: %{public}}@", String(reflecting: self.podState?.messageTransportState))
    }
    
    private func syncSession(_ ltk: Data, _ msgSeq: Int, _ address: UInt32, _ eapSqn: Int) throws -> Int? {
        guard let manager = manager else { throw PodCommsError.noPodPaired }
        let eapAkaExchanger = try SessionEstablisher(manager: manager, ltk: ltk, eapSqn: eapSqn, address: address, msgSeq: msgSeq)

        let result = try eapAkaExchanger.negotiateSessionKeys()
        
        switch result {
        case .SessionNegotiationResynchronization(let keys):
            log.info("EAP AKA resynchronization: %@", keys.synchronizedEapSqn.data.hexadecimalString)
            return keys.synchronizedEapSqn.toInt()
        case .SessionKeys(let keys):
            log.debug("Session Established")
            log.debug("CK: %@", keys.ck.hexadecimalString)
            log.info("msgSequenceNumber: %@", String(keys.msgSequenceNumber))
            log.info("NoncePrefix: %@", keys.nonce.prefix.hexadecimalString)
            
            self.podState?.messageTransportState = MessageTransportState(ck: keys.ck, noncePrefix: keys.nonce.prefix, msgSeq: keys.msgSequenceNumber, nonceSeq: 0)
            
            log.debug("syncSession: set up podState messageTransportState: %@", String(reflecting: self.podState?.messageTransportState))
            return nil
        }
    }
    
    public func establishSession(msgSeq: Int) throws {
        guard var podState = self.podState else {
            throw PodCommsError.noPodPaired
        }
        
        let eapSqn = podState.increaseEapAkaSequenceNumber()

        guard self.podState!.ltk == podState.ltk else {
            throw PodCommsError.invalidData
        }
        guard self.podState!.address == podState.address else {
            throw PodCommsError.invalidData
        }
        var newSqn = try self.syncSession(podState.ltk, msgSeq, podState.address, eapSqn)
        
        if (newSqn != nil) {
            log.debug("Updating EAP SQN to: %d", newSqn!)
            podState.eapAkaSequenceNumber = newSqn!
            newSqn = try self.syncSession(podState.ltk, msgSeq, podState.address, podState.increaseEapAkaSequenceNumber())
            if (newSqn != nil) {
                throw PodCommsError.diagnosticMessage(str: "Received resynchronization SQN for the second time")
            }
        }
    }
    
    private func setupPod(podState: PodState, timeZone: TimeZone) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }

        let transport = PodMessageTransport(manager: manager, address: podState.address, state: podState.messageTransportState)
        transport.messageLogger = messageLogger
        log.debug("setupPod: created transport %@ using podState %@ with messageTransportState %@", String(reflecting: transport), String(reflecting: podState), String(reflecting: podState.messageTransportState))

        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        // XXX Can only use a UInt32 versionResponse lotNo # here
        let setupPod = SetupPodCommand(address: podState.address, dateComponents: dateComponents, lot: UInt32(podState.lotNo & 0xFFFFFFFF), tid: podState.lotSeq)

        let message = Message(address: 0xffffffff, messageBlocks: [setupPod], sequenceNum: transport.messageNumber)

        log.debug("setupPod: calling sendPairMessage %@ for message %@", String(reflecting: transport), String(describing: message))
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

        manager.runSession(withName: "Pair and setup pod") { [weak self] in
            do {
                guard let self = self else { fatalError() }

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

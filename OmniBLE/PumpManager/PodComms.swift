//
//  PodComms.swift
//  OmnipodKit
//
//  Created by Pete Schwamb on 10/7/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import Foundation
import RileyLinkBLEKit
import CoreBluetooth
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
                log.debug("Notifying delegate of new podState: %{public}@", String(reflecting: newValue))
                delegate?.podComms(self, didChange: newValue)
            }
        }
    }
    
    init(podState: PodState?) {
        self.podState = podState
        self.delegate = nil
        self.messageLogger = nil
    }

    /// Handles all the common work to send and verify the version response for the two pairing commands, AssignAddress and SetupPod.
    ///  Has side effects of creating & updating the pod state.
    ///
    /// - parameter address: Address being assigned to the pod
    /// - parameter transport: PodMessageTransport used to send messages
    /// - parameter message: Message to send; must be an AssignAddress or SetupPod
    ///
    /// - returns: The VersionResponse from the pod
    ///
    /// - Throws:
    ///     - PodCommsError.noResponse
    ///     - PodCommsError.emptyResponse
    ///     - PodCommsError.unexpectedResponse
    ///     - PodCommsError.podChange
    ///     - PodCommsError.activationTimeExceeded
    ///     - PodCommsError.podIncompatible
    ///     - MessageError
    ///     - RileyLinkDeviceError
    private func sendPairMessage(address: UInt32, transport: PodMessageTransport, message: Message) throws -> VersionResponse {
        let response: Message = try transport.sendMessage(message)

        if let fault = response.fault {
            log.error("Pod Fault: %{public}@", String(describing: fault))
            if let podState = self.podState, podState.fault == nil {
                self.podState!.fault = fault
            }
            throw PodCommsError.podFault(fault: fault)
        }

        guard let versionResponse = response.messageBlocks[0] as? VersionResponse else {
            log.error("sendPairMessage unexpected response: %{public}@", String(describing: response))
            let responseType = response.messageBlocks[0].blockType
            throw PodCommsError.unexpectedResponse(response: responseType)
        }

        guard versionResponse.address == address else {
            log.error("sendPairMessage unexpected address return of %{public}@ instead of expected %{public}@",
              String(format: "04X", versionResponse.address), String(format: "%04X", address))
            throw PodCommsError.invalidAddress(address: versionResponse.address, expectedAddress: address)
        }

        // If we previously had podState, verify that we are still dealing with the same pod
        if let podState = self.podState, (podState.lot != versionResponse.lot || podState.tid != versionResponse.tid) {
            // Have a new pod, could be a pod change w/o deactivation (or we're picking up some other pairing pod!)
            log.error("Received pod response for [lot %u tid %u], expected [lot %u tid %u]", versionResponse.lot, versionResponse.tid, podState.lot, podState.tid)
            throw PodCommsError.podChange
        }

        if self.podState == nil {
            log.default("Creating PodState for address %{public}@ [lot %u tid %u]", String(format: "%04X", versionResponse.address), versionResponse.lot, versionResponse.tid)
            self.podState = PodState(
                address: versionResponse.address,
                piVersion: String(describing: versionResponse.piVersion),
                pmVersion: String(describing: versionResponse.pmVersion),
                lot: versionResponse.lot,
                tid: versionResponse.tid,
                packetNumber: transport.packetNumber,
                messageNumber: transport.messageNumber
            )
            // podState setupProgress state should be addressAssigned
        }

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
        guard versionResponse.podProgressStatus != .activationTimeExceeded else {
            // The 2 hour window for the initial pairing has expired
            self.podState?.setupProgress = .activationTimeout
            throw PodCommsError.activationTimeExceeded
        }

        // It's unlikely that Insulet will release an updated Eros pod using any different fundemental values,
        // so just verify that the fundemental pod constants returned match the expected constant values in the Pod struct.
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
            log.info("Version Response %{public}@ indicates pairing is now complete", String(describing: versionResponse))
            self.podState?.setupProgress = .podPaired
        }

        return versionResponse
    }

    private func assignAddress(address: UInt32, commandSession: CommandSession) throws {
        commandSession.assertOnSessionQueue()

        // ZZZ rework for BLE transport
        let messageTransportState = MessageTransportState(packetNumber: 0, messageNumber: 0)
        let transport = PodMessageTransport(session: commandSession, address: 0xffffffff, state: messageTransportState)

        transport.messageLogger = messageLogger
        
        // Create the Assign Address command message
        let assignAddress = AssignAddressCommand(address: address)
        let message = Message(address: 0xffffffff, messageBlocks: [assignAddress], sequenceNum: transport.messageNumber)

        _ = try sendPairMessage(address: address, transport: transport, message: message)
    }
    
    private func setupPod(podState: PodState, timeZone: TimeZone, commandSession: CommandSession) throws {
        commandSession.assertOnSessionQueue()

        // ZZZ rework for BLE transport
        let messageTransportState = MessageTransportState(packetNumber: 0, messageNumber: 0)
        let transport = PodMessageTransport(session: commandSession, address: 0xffffffff, state: messageTransportState)

        transport.messageLogger = messageLogger

        // Create the SetupPod command message
        let dateComponents = SetupPodCommand.dateComponents(date: Date(), timeZone: timeZone)
        let setupPod = SetupPodCommand(address: podState.address, dateComponents: dateComponents, lot: podState.lot, tid: podState.tid)
        let message = Message(address: podState.address, messageBlocks: [setupPod], sequenceNum: 0)

        let versionResponse = try sendPairMessage(address: podState.address, transport: transport, message: message)

        guard versionResponse.isSetupPodVersionResponse else {
            log.error("SetupPod unexpected VersionResponse type: %{public}@", String(describing: versionResponse))
            throw PodCommsError.invalidData
        }
    }
    
    func assignAddressAndSetupPod(
        address: UInt32,
        timeZone: TimeZone,
        messageLogger: MessageLogger?,
        _ block: @escaping (_ result: SessionRunResult) -> Void
    ) {
        manager?.runSession(withName: "Pair Pod") { (commandSession) in
            do {
                if self.podState == nil {
                    try self.assignAddress(address: address, commandSession: commandSession)
                }
                
                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

                if self.podState!.setupProgress.isPaired == false {
                    try self.setupPod(podState: self.podState!, timeZone: timeZone, commandSession: commandSession)
                }

                guard self.podState!.setupProgress.isPaired else {
                    self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                    throw PodCommsError.invalidData
                }

                // Run a session now for any post-pairing commands
                // ZZZ rework for BLE transport
                let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: self.podState!.messageTransportState)
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

        manager?.runSession(withName: name) { (commandSession) in
            guard self.podState != nil else {
                block(.failure(PodCommsError.noPodPaired))
                return
            }

            let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: self.podState!.messageTransportState)
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

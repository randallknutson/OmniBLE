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
    
    private let opsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.randallknutson.OmniBLE.PodComms.OpsQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()
    
    private let delegateQueue = DispatchQueue(label: "com.randallknutson.OmnipodKit.delegateQueue", qos: .unspecified)
    
    private func sendHello(_ ids: Ids) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }

        try manager.sendHello(ids.myId.address)
    }
    
    private func pairPod(_ ids: Ids) throws {
        guard let manager = manager else { throw PodCommsError.noPodAvailable }

        let ltkExchanger = LTKExchanger(manager: manager, ids: ids)
        let response = try ltkExchanger.negotiateLTK()
        
        log.debug("Done")

//        if self.podState == nil {
//            log.default("Creating PodState for address %{public}@ [lot %u tid %u]", String(format: "%04X", response.address))
//            self.podState = PodState(
//                address: response.address,
//                ltk: response.ltk,
//                messageSequence: response.msgSeq,
//                lotNo: 0, // TODO: Fix
//                lotSeq: 0
//            )
//            // podState setupProgress state should be addressAssigned
//        }

        // Now that we have podState, check for an activation timeout condition that can be noted in setupProgress
//        guard response.podProgressStatus != .activationTimeExceeded else {
//            // The 2 hour window for the initial pairing has expired
//            self.podState?.setupProgress = .activationTimeout
//            throw PodCommsError.activationTimeExceeded
//        }

        // It's unlikely that Insulet will release an updated Eros pod using any different fundemental values,
        // so just verify that the fundemental pod constants returned match the expected constant values in the Pod struct.
        // To actually be able to handle different fundemental values in Loop things would need to be reworked to save
        // these values in some persistent PodState and then make sure that everything properly works using these values.
//        var errorStrings: [String] = []
//        if let pulseSize = response.pulseSize, pulseSize != Pod.pulseSize  {
//            errorStrings.append(String(format: "Pod reported pulse size of %.3fU different than expected %.3fU", pulseSize, Pod.pulseSize))
//        }
//        if let secondsPerBolusPulse = response.secondsPerBolusPulse, secondsPerBolusPulse != Pod.secondsPerBolusPulse  {
//            errorStrings.append(String(format: "Pod reported seconds per pulse rate of %.1f different than expected %.1f", secondsPerBolusPulse, Pod.secondsPerBolusPulse))
//        }
//        if let secondsPerPrimePulse = response.secondsPerPrimePulse, secondsPerPrimePulse != Pod.secondsPerPrimePulse  {
//            errorStrings.append(String(format: "Pod reported seconds per prime pulse rate of %.1f different than expected %.1f", secondsPerPrimePulse, Pod.secondsPerPrimePulse))
//        }
//        if let primeUnits = response.primeUnits, primeUnits != Pod.primeUnits {
//            errorStrings.append(String(format: "Pod reported prime bolus of %.2fU different than expected %.2fU", primeUnits, Pod.primeUnits))
//        }
//        if let cannulaInsertionUnits = response.cannulaInsertionUnits, Pod.cannulaInsertionUnits != cannulaInsertionUnits {
//            errorStrings.append(String(format: "Pod reported cannula insertion bolus of %.2fU different than expected %.2fU", cannulaInsertionUnits, Pod.cannulaInsertionUnits))
//        }
//        if let serviceDuration = response.serviceDuration {
//            if serviceDuration < Pod.serviceDuration {
//                errorStrings.append(String(format: "Pod reported service duration of %.0f hours shorter than expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours))
//            } else if serviceDuration > Pod.serviceDuration {
//                log.info("Pod reported service duration of %.0f hours limited to expected %.0f", serviceDuration.hours, Pod.serviceDuration.hours)
//            }
//        }

//        let errMess = errorStrings.joined(separator: ".\n")
//        if errMess.isEmpty == false {
//            log.error("%@", errMess)
//            self.podState?.setupProgress = .podIncompatible
//            throw PodCommsError.podIncompatible(str: errMess)
//        }
//
//        if response.podProgressStatus == .pairingCompleted && self.podState?.setupProgress.isPaired == false {
//            log.info("Version Response %{public}@ indicates pairing is now complete", String(describing: response))
//            self.podState?.setupProgress = .podPaired
//        }
    }
    
    func assignAddressAndSetupPod(
        address: UInt32,
        timeZone: TimeZone,
        messageLogger: MessageLogger?,
        _ block: @escaping (_ result: SessionRunResult) -> Void
    ) {
        delegateQueue.async { [weak self] in
            guard let self = self else { fatalError() }
            self.log.debug("assignAddressAndSetupPod")
            
            do {
                if self.podState == nil {
                    let ids = Ids(podState: self.podState)
                    self.opsQueue.addOperation {
                        do {
                            self.log.debug("")
                            try self.sendHello(ids)
                        } catch let error as PodCommsError {
                            block(.failure(error))
                        } catch {
                            block(.failure(PodCommsError.commsError(error: error)))
                        }
                    }
                    self.opsQueue.addOperation {
                        do {
                            try self.pairPod(ids)
                        } catch let error as PodCommsError {
                            block(.failure(error))
                        } catch {
                            block(.failure(PodCommsError.commsError(error: error)))
                        }
                    }
                }
                
                self.opsQueue.waitUntilAllOperationsAreFinished()
                
                guard self.podState != nil else {
                    block(.failure(PodCommsError.noPodPaired))
                    return
                }

    //            if self.podState!.setupProgress.isPaired == false {
    //                try self.setupPod(podState: self.podState!, timeZone: timeZone, commandSession: commandSession)
    //            }

                guard self.podState!.setupProgress.isPaired else {
                    self.log.error("Unexpected podStatus setupProgress value of %{public}@", String(describing: self.podState!.setupProgress))
                    throw PodCommsError.invalidData
                }

                // Run a session now for any post-pairing commands
                // ZZZ rework for BLE transport
    //            let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: self.podState!.messageTransportState)
    //            transport.messageLogger = self.messageLogger
    //            let podSession = PodCommsSession(podState: self.podState!, transport: transport, delegate: self)
    //
    //            block(.success(session: podSession))
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

            let transport = PodMessageTransport(session: commandSession, address: self.podState!.address, state: MessageTransportState(rawValue: NSObject() as! MessageTransportState.RawValue)!)
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

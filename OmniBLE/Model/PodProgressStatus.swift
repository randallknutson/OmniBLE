//
//  PodProgressStatus.swift
//  OmniBLEKit
//
//  Created by Pete Schwamb on 9/28/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//  Copyright © 2021 Joseph Moran. All rights reserved.
//

import Foundation

public enum PodProgressStatus: UInt8, CustomStringConvertible, Equatable {
    case initialized = 0
    case memoryInitialized = 1
    case reminderInitialized = 2
    case pairingCompleted = 3
    case priming = 4
    case primingCompleted = 5
    case basalInitialized = 6
    case insertingCannula = 7
    case aboveFiftyUnits = 8
    case fiftyOrLessUnits = 9
    case faultEventOccurred = 10        // fault event occurred (a "screamer")
    case activationTimeExceeded = 11    // took > 2 hrs from progress 2 to 3 OR > 1 hr from 3 to 8
    case inactive = 12                  // pod deactivated or a fatal packet state error
    case manufacturingTest = 13
    case unused14 = 14
    case unused15 = 15
    
    public var readyForDelivery: Bool {
        return self == .fiftyOrLessUnits || self == .aboveFiftyUnits
    }
    
    public var description: String {
        switch self {
        case .initialized:
            return LocalizedString("Initialized", comment: "Pod initialized")
        case .memoryInitialized:
            return LocalizedString("Memory initialized", comment: "Pod memory initialized")
        case .reminderInitialized:
            return LocalizedString("Reminder initialized", comment: "Pod pairing reminder initialized")
        case .pairingCompleted:
            return LocalizedString("Pairing completed", comment: "Pod status when pairing completed")
        case .priming:
            return LocalizedString("Priming", comment: "Pod status when priming")
        case .primingCompleted:
            return LocalizedString("Priming completed", comment: "Pod state when priming completed")
        case .basalInitialized:
            return LocalizedString("Basal initialized", comment: "Pod state when basal initialized")
        case .insertingCannula:
            return LocalizedString("Inserting cannula", comment: "Pod state when inserting cannula")
        case .aboveFiftyUnits:
            return LocalizedString("Normal", comment: "Pod state when running above fifty units")
        case .fiftyOrLessUnits:
            return LocalizedString("Low reservoir", comment: "Pod state when running with fifty or less units")
        case .faultEventOccurred:
            return LocalizedString("Fault event occurred", comment: "Pod state when fault event has occurred")
        case .activationTimeExceeded:
            return LocalizedString("Activation time exceeded", comment: "Pod state when activation not completed in the time allowed")
        case .inactive:
            return LocalizedString("Deactivated", comment: "Pod state when deactivated")
        case .manufacturingTest:
            return LocalizedString("oneNotUsed", comment: "Pod state oneNotUsed")
        case .unused14:
            return LocalizedString("twoNotUsed", comment: "Pod state unused 14")
        case .unused15:
            return LocalizedString("threeNotUsed", comment: "Pod state unused 15")
        }
    }
}

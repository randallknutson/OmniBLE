//
//  PeripheralManagerErrors.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/18/21.
//

import Foundation

enum PeripheralManagerError: Error {
    case cbPeripheralError(Error)
    case notReady
    case incorrectResponse
    case timeout([PeripheralManager.CommandCondition])
    case emptyValue
    case unknownCharacteristic
    case serviceNotFound
    case nack
}


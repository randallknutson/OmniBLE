//
//  BluetoothErrors.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/3/21.
//

import Foundation
import CoreBluetooth

enum BluetoothErrors: Error {
    case DiscoveredInvalidPodException(_ message: String, _ data: [CBUUID])
    case InvalidLTKKey(_ message: String)
    case PairingException(_ message: String)
    case MessageIOException(_ message: String)
    case CouldNotParseMessageException(_ message: String)
    case IncorrectPacketException(_ payload: Data, _ location: Int)
}


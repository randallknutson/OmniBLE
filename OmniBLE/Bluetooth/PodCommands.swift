//
//  PodCommands.swift
//  OmniBLE
//
//  Created by Randall Knutson on 8/17/21.
//

import Foundation

enum PodCommand: UInt8 {
    case RTS = 0x00
    case CTS = 0x01
    case NACK = 0x02
    case ABORT = 0x03
    case SUCCESS = 0x04
    case FAIL = 0x05
    case HELLO = 0x06
    case INCORRECT = 0x09
}

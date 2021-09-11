//
//  MessageType.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/4/21.
//

import Foundation

enum MessageType: UInt8 {
    case CLEAR = 0, ENCRYPTED, SESSION_ESTABLISHMENT, PAIRING
}

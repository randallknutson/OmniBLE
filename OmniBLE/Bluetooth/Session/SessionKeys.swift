//
//  SessionKeys.swift
//  OmniBLE
//
//  Created by Randall Knutson on 11/8/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//

import Foundation

struct SessionKeys {
    var ck: Data
    var nonce: Nonce
    var msgSequenceNumber: UInt8
}

struct SessionNegotiationResynchronization {
    let synchronizedEapSqn: EapSqn
    let msgSequenceNumber: UInt8
}

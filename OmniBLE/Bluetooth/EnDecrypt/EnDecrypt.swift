//
//  EnDecrypt.swift
//  OmniBLE
//
//  Created by Randall Knutson on 11/4/21.
//  Copyright © 2021 Randall Knutson. All rights reserved.
//

import Foundation
import CryptoSwift
import os.log

class EnDecrypt {
    private let MAC_SIZE = 8
    private let log = OSLog(category: "EnDecrypt")
    private let nonce: Nonce
    private let ck: Data

    init(nonce: Nonce, ck: Data) {
        self.nonce = nonce
        self.ck = ck
    }

    func decrypt(_ msg: Message) throws -> Message {
        let payload = msg.payload
        let header = msg.asData().subdata(in: 0..<16)

        let n = nonce.increment(podReceiving: false)
        log.debug("Decrypt header %@ payload: %@", header.hexadecimalString, payload.hexadecimalString)
        log.debug("Decrypt NONCE %@", n.hexadecimalString)
        let ccm = CCM(iv: n.bytes, tagLength: MAC_SIZE, messageLength: payload.count, additionalAuthenticatedData: header.bytes)
        let aes = try AES(key: ck.bytes, blockMode: ccm, padding: .noPadding)
        let decryptedPayload = try aes.decrypt(payload.bytes)
        log.debug("Decrypted payload %@", Data(decryptedPayload).hexadecimalString)
        
        var msgCopy = msg
        msgCopy.payload = Data(decryptedPayload)
        return msgCopy
    }

    func encrypt(_ headerMessage: Message) throws -> Message {
        let payload = headerMessage.payload
        let header = headerMessage.asData().subdata(in: 0..<16)

        let n = nonce.increment(podReceiving: true)
        log.debug("Encrypt header %@ payload: %@", header.hexadecimalString, payload.hexadecimalString)
        log.debug("Encrypt NONCE %@", n.hexadecimalString)
        let ccm = CCM(iv: n.bytes, tagLength: MAC_SIZE, messageLength: payload.count, additionalAuthenticatedData: header.bytes)
        let aes = try AES(key: ck.bytes, blockMode: ccm, padding: .noPadding)
        let encryptedPayload = try aes.encrypt(payload.bytes)

        var msgCopy = headerMessage
        msgCopy.payload = Data(encryptedPayload)
        return msgCopy
    }
}

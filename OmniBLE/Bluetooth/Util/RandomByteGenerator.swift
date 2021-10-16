//
//  RandomByteGenerator.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/8/21.
//

import Foundation
class RandomByteGenerator {
    func nextBytes(length: Int) -> Data {
        var bytes = [Int8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess { // Always test the status.
            return Data(bytes: bytes, count: bytes.count)
        }
        return Data()
    }
}

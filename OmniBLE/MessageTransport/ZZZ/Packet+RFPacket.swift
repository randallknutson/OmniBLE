//
//  Packet+RFPacket.swift
//  OmniBLEKit
//
//  Created by Pete Schwamb on 12/19/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation
// ZZZ import RileyLinkBLEKit

// Extensions for RFPacket support
extension Packet {
    init(rfPacket: RFPacket) throws {
        try self.init(encodedData: rfPacket.data)
    }
}

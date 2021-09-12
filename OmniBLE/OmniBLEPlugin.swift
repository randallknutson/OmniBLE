//
//  OmniBLEPlugin.swift
//  OmniBLEPlugin
//
//  Created by Randall Knutson on 09/11/21.
//

import Foundation
import LoopKitUI
import OmniKit
import OmniKitUI
import os.log

class OmniBLEPlugin: NSObject, LoopUIPlugin {
    private let log = OSLog(category: "OmniBLEPlugin")
    
    public var pumpManagerType: PumpManagerUI.Type? {
        return OmniBLEPumpManager.self
    }
    
    public var cgmManagerType: CGMManagerUI.Type? {
        return nil
    }
    
    override init() {
        super.init()
        log.default("OmniBLEPlugin Instantiated")
    }
}

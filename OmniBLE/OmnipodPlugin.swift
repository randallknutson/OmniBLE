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

class OmnipodPlugin: NSObject, LoopUIPlugin {
    private let log = OSLog(category: "OmnipodPlugin")
    
    public var pumpManagerType: PumpManagerUI.Type? {
        return OmnipodPumpManager.self
    }
    
    public var cgmManagerType: CGMManagerUI.Type? {
        return nil
    }
    
    override init() {
        super.init()
        log.default("OmnipodPlugin Instantiated")
    }
}

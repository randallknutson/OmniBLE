//
//  Ids.swift
//  OmnipodKit
//
//  Created by Randall Knutson on 8/5/21.
//

import Foundation

let CONTROLLER_ID: Int = 4242
let POD_ID_NOT_ACTIVATED = Data(hexadecimalString: "FFFFFFFE")!

class Ids {
    static func notActivated() -> Id {
        return Id(POD_ID_NOT_ACTIVATED)
    }
    static func controllerId() -> Id {
        return Id.fromInt(CONTROLLER_ID)
    }
    let myId: Id
    let podId: Id
    
    init(podState: PodState?) {
        myId = Id.fromInt(CONTROLLER_ID)
        let uniqueId = podState != nil ? Id.fromLong(podState!.address) : myId
        podId = uniqueId.increment()
    }
}

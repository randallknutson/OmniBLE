//
//  Ids.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/5/21.
//

import Foundation

let CONTROLLER_ID: Int32 = 4242 // TODO read from preferences or somewhere else.
let POD_ID_NOT_ACTIVATED = Int64(0xFFFFFFFE)

class Ids {
    static func notActivated() -> Id {
        return Id.fromLong(POD_ID_NOT_ACTIVATED)
    }
    let myId: Id
    let podId: Id
    
    init(podState: PodState?) {
        myId = Id.fromInt(CONTROLLER_ID)
        // TODO:
//        guard let uniqueId = podState?.uniqueId else {
//            podId = myId.increment()
//            return
//        }
//        podId = Id.fromLong(uniqueId)
        podId = Ids.notActivated()
    }
}

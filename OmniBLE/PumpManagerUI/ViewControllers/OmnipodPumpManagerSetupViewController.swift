//
//  OmnipodPumpManagerSetupViewController.swift
//  OmnipodKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import Foundation

import UIKit
import LoopKit
import LoopKitUI
import OmniKit

// PumpManagerSetupViewController
public class OmnipodPumpManagerSetupViewController: UINavigationController, PumpManagerSetupViewController, UINavigationControllerDelegate, CompletionNotifying {
    public var setupDelegate: PumpManagerSetupViewControllerDelegate?
    
    public var maxBasalRateUnitsPerHour: Double?
    
    public var maxBolusUnits: Double?
    
    public var basalSchedule: BasalRateSchedule?
    
    public var completionDelegate: CompletionDelegate?
    
    class func instantiateFromStoryboard() -> OmnipodPumpManagerSetupViewController {
        return UIStoryboard(name: "OmnipodPumpManager", bundle: Bundle(for: OmnipodPumpManagerSetupViewController.self)).instantiateInitialViewController() as! OmnipodPumpManagerSetupViewController
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        
        if #available(iOSApplicationExtension 13.0, *) {
            // Prevent interactive dismissal
            isModalInPresentation = true
            view.backgroundColor = .systemBackground
        } else {
            view.backgroundColor = .white
        }
        navigationBar.shadowImage = UIImage()

        delegate = self
    }
        
    private(set) var pumpManager: OmnipodPumpManager?
    
    /*
     1. Basal Rates & Delivery Limits
     
     2. Pod Pairing/Priming
     
     3. Cannula Insertion
     
     4. Pod Setup Complete
     */
    
    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // Read state values
        let viewControllers = navigationController.viewControllers
        let count = navigationController.viewControllers.count
        
        if count >= 2 {
            switch viewControllers[count - 2] {
            case let vc as PairPodSetupViewController:
                pumpManager = vc.pumpManager
            default:
                break
            }
        }

        if let setupViewController = viewController as? SetupTableViewController {
            setupViewController.delegate = self
        }


        // Set state values
        switch viewController {
        case let vc as PairPodSetupViewController:
            if let basalSchedule = basalSchedule {
                let schedule = BasalSchedule(repeatingScheduleValues: basalSchedule.items)
                let pumpManagerState = OmnipodPumpManagerState(podState: nil, timeZone: .currentFixed, basalSchedule: schedule)
                let pumpManager = OmnipodPumpManager(state: pumpManagerState)
                vc.pumpManager = pumpManager
                setupDelegate?.pumpManagerSetupViewController(self, didSetUpPumpManager: pumpManager)
            }
        case let vc as InsertCannulaSetupViewController:
            vc.pumpManager = pumpManager
        case let vc as PodSetupCompleteViewController:
            vc.pumpManager = pumpManager
        default:
            break
        }
    }

    open func finishedSetup() {
        if let pumpManager = pumpManager {
            let settings = OmnipodSettingsViewController(pumpManager: pumpManager)
            setViewControllers([settings], animated: true)
        }
    }

    public func finishedSettingsDisplay() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

extension OmnipodPumpManagerSetupViewController: SetupTableViewControllerDelegate {
    public func setupTableViewControllerCancelButtonPressed(_ viewController: SetupTableViewController) {
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

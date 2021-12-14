# OmniBLE
Omnipod Bluetooth PumpManager For Loop

## Status
This module is at the very beginning stages of development and does not even compile yet. DO NOT ATTEMPT to use it unless you are a developer trying to help out build it.

## WARNING: DO NOT ATTEMPT to use this on a real person. 
It has not been tested yet in any way.

## Unit Tests

Unit testing is supported for the simulator only. The process for running OmniBLE unit tests depends on which Xcode workspace/project is open. The suggested process for running unit tests are:

1. Open Loop Workspace
2. Build the Loop Workspace target for the iPhone simulator 1x to build all dependencies.
3. Run OmniBLE tests for iPhone Simulator from Xcode Workspace.

You can also run unit tests from the standalone OmniBLE.xcodeproj (no Loop workspace open), but this requires the dependencies to be fetched from Carthage. The following steps should work but are not supported for Apple Silicon Macs: 

1. From OmniBLE project directory: `./carthage.sh update --platform iOS`
2. Open OmniBLE.xcodeproj
3. Uncomment the `copy-frameworks` command in the "Copy Frameworks with Carthage" build step.
4. Run tests for the iPhone simulator.
5. Undo your change in step 3 as it should not be checked into source control (not compatible with Loop Workspace build method)

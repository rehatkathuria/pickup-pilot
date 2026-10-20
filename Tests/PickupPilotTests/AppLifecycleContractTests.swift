import AppKit
import Testing
@testable import PickupPilot

@MainActor @Test func closingSetupWindowKeepsMenuBarAgentAlive() {
    let delegate = PilotAppDelegate()
    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}

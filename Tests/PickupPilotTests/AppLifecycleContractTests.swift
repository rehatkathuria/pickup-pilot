import AppKit
import PilotCore
import Testing
@testable import PickupPilot

@MainActor @Test func closingSetupWindowKeepsMenuBarAgentAlive() {
    let delegate = PilotAppDelegate()
    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}

@MainActor @Test func ordinaryLaunchUsesDiscoverableApplicationPolicy() {
    let delegate = PilotAppDelegate()
    var policies: [NSApplication.ActivationPolicy] = []
    delegate.setActivationPolicy = { policies.append($0) }
    delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
    #expect(policies == [.regular])
}

@MainActor @Test(arguments: [false, true]) func reopeningShowsMainWindowWithoutChangingArming(hasVisibleWindows: Bool) {
    let delegate = PilotAppDelegate()
    var windowsOpened = 0
    var activations = 0
    var armed = false
    delegate.isArmedCheck = { armed }
    delegate.openMainWindow = { windowsOpened += 1 }
    delegate.activateApplication = { activations += 1 }

    #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
    #expect(windowsOpened == 1)
    #expect(activations == 1)
    #expect(!delegate.isArmedCheck())
    armed = true
    #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: hasVisibleWindows))
    #expect(windowsOpened == 2)
    #expect(delegate.isArmedCheck())
}

@MainActor @Test func duplicateLaunchFocusesExistingOwnerAndTerminatesNewCopy() {
    let delegate = PilotAppDelegate()
    var activations = 0
    var terminations = 0
    var alerts = 0
    delegate.focusExistingApplication = { activations += 1; return true }
    delegate.showLaunchError = { _, _ in alerts += 1 }
    delegate.terminateApplication = { terminations += 1 }

    delegate.handleInstanceLockFailure(SingleInstanceLock.InstanceError.alreadyRunning)

    #expect(activations == 1)
    #expect(terminations == 1)
    #expect(alerts == 0)
}

@MainActor @Test func ambiguousDuplicateAndUnavailableLockRemainDistinctFailures() {
    let delegate = PilotAppDelegate()
    var existingAppLookups = 0
    var terminations = 0
    var titles: [String] = []
    delegate.focusExistingApplication = { existingAppLookups += 1; return false }
    delegate.showLaunchError = { title, _ in titles.append(title) }
    delegate.terminateApplication = { terminations += 1 }

    delegate.handleInstanceLockFailure(SingleInstanceLock.InstanceError.alreadyRunning)
    delegate.handleInstanceLockFailure(SingleInstanceLock.InstanceError.cannotOpen)

    #expect(existingAppLookups == 1)
    #expect(terminations == 2)
    #expect(titles == ["Pickup Pilot is already open.", "Pickup Pilot could not open its local lock."])
}

import Foundation
import Synchronization
import Testing
@testable import PickupPilot

/// Uses an in-memory executor or osascript with local return/delay statements only.
/// These tests never start Safari, read a browser tab, or touch a live checkout.
@Suite(.serialized) @MainActor struct SafariAutomationTests {
    @Test func createsOnlyAnExplicitNewBlankDocumentAndPinsEverySubsequentAction() async throws {
        let executor = SafariTransportMock(["PPOK\t71\n", "PPOK\t\n", "PPOK\thttps://www.apple.com/ca/shop/bag\n", "PPOK\t{\"ok\":true}\n", "PPOK\t\n", "PPOK\t\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let handle = try await safari.createWindow()
        #expect(handle.id == 71)
        try await safari.navigate(URL(string: "https://www.apple.com/ca/shop/bag")!, in: handle)
        #expect(try await safari.currentURL(in: handle)?.path == "/ca/shop/bag")
        #expect(try await safari.evaluate(script: "JSON.stringify({ok:true})", in: handle) == "{\"ok\":true}")
        try await safari.activate(handle)
        try await safari.close(handle)
        let scripts = await executor.scripts
        #expect(scripts.count == 6)
        #expect(scripts[0].contains("make new document with properties {URL:\"about:blank\"}"))
        #expect(scripts[0].contains("set previousIDs to id of every window"))
        for script in scripts.dropFirst() {
            #expect(script.contains("every window whose id is 71"))
            #expect(script.contains("window.name ==="))
            #expect(!script.contains("front window"))
            #expect(script.contains("ownedTab"))
        }
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.activate(handle) }
        #expect(await executor.scripts.count == 6)
    }

    @Test func forgedOrForeignHandlesNeverReachSafari() async throws {
        let executor = SafariTransportMock(["PPOK\t7\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.navigate(URL(string: "https://www.apple.com")!, in: SafariWindowHandle(id: 7)) }
        _ = try await safari.createWindow()
        for id in [0, -1, 8] {
            await #expect(throws: SafariAutomationError.windowLost) { _ = try await safari.evaluate(script: "JSON.stringify({})", in: SafariWindowHandle(id: id)) }
        }
        #expect(await executor.scripts.count == 1)
    }

    @Test func onlyPendingNavigationMayRecaptureAndMovedTabsPermanentlyDisableIt() async throws {
        let bag = "https://www.apple.com/ca/shop/bag"
        let executor = SafariTransportMock(["PPOK\t81\n", "PPOK\tPPTRACK\t0\t\(bag)\n",
            "PPOK\tPPTRACK\t0\t\(bag)\n", "PPOK\tPPTRACK\t0\t\(bag)\n",
            "PPOK\tPPTRACK\t1\t\(bag)\n", "PPOK\tPPTRACK\t0\t\(bag)\n", "PPOK\tPPTRACK\t0\t\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let handle = try await safari.createWindow()
        _ = try await safari.currentURL(in: handle)
        try safari.expectNavigation(in: handle)
        _ = try await safari.currentURL(in: handle)
        safari.confirmDocument(in: handle)
        _ = try await safari.currentURL(in: handle)
        try safari.expectNavigation(in: handle)
        _ = try await safari.currentURL(in: handle)
        try safari.expectNavigation(in: handle)
        _ = try await safari.currentURL(in: handle)
        try await safari.close(handle)
        let scripts = await executor.scripts
        #expect(!scripts[1].contains("set navigationRecoveryDeadline"))
        #expect(scripts[2].contains("set navigationRecoveryDeadline"))
        #expect(!scripts[3].contains("set navigationRecoveryDeadline"))
        #expect(scripts[4].contains("set navigationRecoveryDeadline"))
        #expect(!scripts[5].contains("set navigationRecoveryDeadline"))
        #expect(!scripts[6].contains("set recoveredDocument") && scripts[6].contains("close ownedTab"))
    }

    @Test(arguments: ["0", "-3", "untrusted page", "7.0"])
    func invalidCreationResultsNeverBecomeOwnedWindows(value: String) async {
        let executor = SafariTransportMock(["PPOK\t\(value)\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        await #expect(throws: SafariAutomationError.invalidResult) { _ = try await safari.createWindow() }
    }

    @Test func duplicateCreationIDCannotAdoptAnExistingWindow() async throws {
        let executor = SafariTransportMock(["PPOK\t7\n", "PPOK\t7\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        _ = try await safari.createWindow()
        await #expect(throws: SafariAutomationError.invalidResult) { _ = try await safari.createWindow() }
    }

    @Test func unavailableSafariDoesNotStartAnExecutor() async {
        let executor = SafariTransportMock([])
        let safari = SafariAutomation(executor: executor, isAvailable: { false }, processIdentity: { Self.syntheticProcess })
        await #expect(throws: SafariAutomationError.unavailable) { _ = try await safari.createWindow() }
        #expect(await executor.scripts.isEmpty)
    }

    @Test func singleFlightRejectsOverlapAndCancellationDiscardsLateCreatedWindow() async throws {
        let executor = SafariTransportMock(["PPOK\t19\n"])
        await executor.setPaused(true)
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let pending = Task { try await safari.createWindow() }
        try await waitUntilStarted(executor)
        await #expect(throws: SafariAutomationError.operationInProgress) { _ = try await safari.createWindow() }
        safari.cancel()
        await executor.release()
        await #expect(throws: SafariAutomationError.cancelled) { _ = try await pending.value }
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.activate(SafariWindowHandle(id: 19)) }
        #expect(executor.cancellationCount > 0)
        #expect(await executor.scripts.count == 1)
    }

    @Test func callerTaskCancellationAlsoRejectsAnIgnoredLateResponse() async throws {
        let executor = SafariTransportMock(["PPOK\t20\n"])
        await executor.setPaused(true)
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let pending = Task { try await safari.createWindow() }
        try await waitUntilStarted(executor)
        pending.cancel()
        await executor.release()
        await #expect(throws: SafariAutomationError.cancelled) { _ = try await pending.value }
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.close(SafariWindowHandle(id: 20)) }
    }

    @Test func cancellationCanBeFollowedByANewExplicitOperation() async throws {
        let executor = SafariTransportMock(["PPOK\t22\n", "PPOK\t23\n"])
        await executor.setPaused(true)
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let pending = Task { try await safari.createWindow() }
        try await waitUntilStarted(executor)
        safari.cancel()
        await executor.release()
        _ = try? await pending.value
        #expect(try await safari.createWindow().id == 23)
    }

    @Test func unknownErrorsAndDescriptionsNeverEchoScriptOrPageContents() async {
        let executor = SafariTransportMock([])
        await executor.failWithSyntheticPrivateText()
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        do { _ = try await safari.createWindow(); Issue.record("Expected sanitized transport failure") }
        catch {
            #expect(error as? SafariAutomationError == .operationFailed(code: nil))
            #expect(!String(describing: error).contains("synthetic-private-value"))
            #expect(!error.localizedDescription.contains("synthetic-private-value"))
        }
        let handle = SafariWindowHandle(id: 123456)
        #expect(!String(describing: handle).contains("123456"))
        #expect(!String(reflecting: handle).contains("123456"))
    }

    @Test(arguments: [
        (-1743, SafariAutomationError.permissionDenied), (8, .javascriptDisabled), (-27004, .javascriptDisabled),
        (-1712, .timeout), (-128, .cancelled), (-600, .unavailable), (-609, .unavailable),
        (-1728, .navigationChanged), (-27005, .navigationChanged), (-27001, .windowLost), (-27002, .ambiguousWindow), (-27003, .invalidResult), (-1708, .operationFailed(code: -1708))
    ])
    func numericAppleEventErrorsMapToFixedActionableErrors(code: Int, expected: SafariAutomationError) async {
        let executor = SafariTransportMock(["PPERR\t\(code)\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        await #expect(throws: expected) { _ = try await safari.createWindow() }
    }

    @Test func framingPreservesJSONAndRejectsUnframedDiagnostics() throws {
        #expect(try SafariAppleScript.decode("PPOK\t{\"message\":\"line\\nnext\"}\n") == "{\"message\":\"line\\nnext\"}")
        #expect(try SafariAppleScript.decode("PPOK\tvalue\r\n") == "value\r")
        for value in ["", "synthetic-private-value", "PPERR\tsecret\n", "PPOK", "PPERR\t-1743 trailing\n"] {
            #expect(throws: SafariAutomationError.invalidResult) { try SafariAppleScript.decode(value) }
        }
    }

    @Test func scriptLiteralCannotEscapeIntoAppleScriptStatements() {
        let value = "\\\"\nreturn \"synthetic-private-value\"\r\t"
        let literal = SafariAppleScript.literal(value)
        #expect(!literal.contains("\n") && !literal.contains("\r") && !literal.contains("\t"))
        #expect(literal.contains("\\n") && literal.contains("\\r") && literal.contains("\\t") && literal.contains("\\\""))
        let script = SafariAppleScript.inWindow(SafariWindowHandle(id: 3), body: "return \"PPOK\\t\"")
        #expect(script.contains("on error errorText number errorNumber"))
        #expect(script.contains("return \"PPERR\\t\" & errorNumber"))
        #expect(!script.contains("return errorText"))
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,private", "file:///etc/passwd", "http://example.com", "https://user:pass@www.apple.com", "about:config"])
    func unsupportedDestinationsNeverSendAppleEvents(address: String) async throws {
        let executor = SafariTransportMock(["PPOK\t31\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let handle = try await safari.createWindow()
        await #expect(throws: SafariAutomationError.invalidURL) { try await safari.navigate(URL(string: address)!, in: handle) }
        #expect(await executor.scripts.count == 1)
    }

    @Test func onlyHTTPSBlankAndLoopbackHTTPDestinationsAreSupported() {
        for value in ["https://www.apple.com/ca/shop/bag", "about:blank", "http://127.0.0.1:8999/fixture", "http://localhost:8999/fixture", "http://[::1]:8999/fixture"] {
            #expect(SafariAutomation.isSupportedDestination(URL(string: value)!))
        }
    }

    @Test func missingOrMalformedCurrentURLNeverTriggersAPageDataFallback() async throws {
        let executor = SafariTransportMock(["PPOK\t33\n", "PPOK\t\n", "PPOK\tmalformed URL\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let handle = try await safari.createWindow()
        #expect(try await safari.currentURL(in: handle) == nil)
        await #expect(throws: SafariAutomationError.invalidResult) { _ = try await safari.currentURL(in: handle) }
        #expect(await executor.scripts.allSatisfy { !$0.contains("document.body") && !$0.contains("document.cookie") })
    }

    @Test func realExecutorUsesOnlyLocalStatementsAndBoundsTimeout() async throws {
        let executor = SafariScriptExecutor()
        #expect(try await executor.execute("return \"PPOK\\tlocal-only\"", timeout: .seconds(3)) == "PPOK\tlocal-only\n")
        await #expect(throws: SafariAutomationError.timeout) {
            _ = try await executor.execute("delay 30\nreturn \"late\"", timeout: .milliseconds(30))
        }
        #expect(try await executor.execute("return \"reusable\"", timeout: .seconds(3)) == "reusable\n")
    }

    @Test func realExecutorCancellationStopsOnlyItsHelperAndCanBeReused() async throws {
        let executor = SafariScriptExecutor()
        let pending = Task { try await executor.execute("delay 30\nreturn \"late\"", timeout: .seconds(3)) }
        try await Task.sleep(for: .milliseconds(40))
        pending.cancel()
        await #expect(throws: SafariAutomationError.cancelled) { _ = try await pending.value }
        #expect(try await executor.execute("return \"after-cancellation\"", timeout: .seconds(3)) == "after-cancellation\n")
    }

    @Test func realExecutorRoundTripsEscapedSyntheticTextWithoutArgumentsOrFiles() async throws {
        let executor = SafariScriptExecutor()
        let sample = "synthetic quote \" slash \\ newline\n tab\t unicode é end\r"
        let output = try await executor.execute("return " + SafariAppleScript.literal(sample), timeout: .seconds(3))
        #expect(output == sample + "\n")
    }

    private static let syntheticProcess = SafariApplicationIdentity(processIdentifier: 700, launchDate: Date(timeIntervalSince1970: 10))

    @Test func restartedSafariCannotReuseAnOldOwnedWindowIdentifier() async throws {
        let executor = SafariTransportMock(["PPOK\t41\n", "PPOK\t41\n", "PPOK\t\n"])
        var identity: SafariApplicationIdentity? = Self.syntheticProcess
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { identity })
        let oldWindow = try await safari.createWindow()
        identity = SafariApplicationIdentity(processIdentifier: 701, launchDate: Date(timeIntervalSince1970: 20))
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.close(oldWindow) }
        #expect(await executor.scripts.count == 1)
        let newlyCreated = try await safari.createWindow()
        #expect(newlyCreated.id == oldWindow.id)
        try await safari.activate(newlyCreated)
        #expect(await executor.scripts.count == 3)
    }

    @Test func missingProcessOrPIDReuseWithDifferentLaunchDateInvalidatesAllHandles() async throws {
        for replacement in [nil, SafariApplicationIdentity(processIdentifier: 700, launchDate: Date(timeIntervalSince1970: 11))] {
            let executor = SafariTransportMock(["PPOK\t42\n", "PPOK\t43\n"])
            var identity: SafariApplicationIdentity? = Self.syntheticProcess
            let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { identity })
            let first = try await safari.createWindow(), second = try await safari.createWindow()
            identity = replacement
            await #expect(throws: SafariAutomationError.windowLost) { _ = try await safari.currentURL(in: first) }
            identity = Self.syntheticProcess
            await #expect(throws: SafariAutomationError.windowLost) { try await safari.activate(second) }
            #expect(await executor.scripts.count == 2)
        }
    }

    @Test func restartDuringAnInFlightOperationRejectsLateResponseAndFutureCommands() async throws {
        let executor = SafariTransportMock(["PPOK\t44\n", "PPOK\t{\"ok\":true}\n"])
        var identity: SafariApplicationIdentity? = Self.syntheticProcess
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { identity })
        let window = try await safari.createWindow()
        await executor.setPaused(true)
        let pending = Task { try await safari.evaluate(script: "JSON.stringify({ok:true})", in: window) }
        for _ in 0..<100 {
            if await executor.scripts.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        identity = SafariApplicationIdentity(processIdentifier: 702, launchDate: Date(timeIntervalSince1970: 30))
        await executor.release()
        await #expect(throws: SafariAutomationError.windowLost) { _ = try await pending.value }
        await #expect(throws: SafariAutomationError.windowLost) { try await safari.close(window) }
        #expect(await executor.scripts.count == 2)
    }

    @Test func closeWaitsForCancelledOperationToUnwindAndDispatchesCloseOnlyOnce() async throws {
        let executor = SafariTransportMock(["PPOK\t46\n", "PPOK\tlate\n", "PPOK\t\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let window = try await safari.createWindow()
        await executor.setPaused(true)
        let pending = Task { try await safari.evaluate(script: "JSON.stringify({synthetic:true})", in: window) }
        for _ in 0..<100 {
            if await executor.scripts.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        safari.cancel()
        let closing = Task { try await safari.close(window) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await executor.scripts.count == 2)
        await #expect(throws: SafariAutomationError.operationInProgress) { try await safari.close(window) }
        await executor.release()
        await #expect(throws: SafariAutomationError.cancelled) { _ = try await pending.value }
        try await closing.value
        let scripts = await executor.scripts
        #expect(scripts.filter { $0.contains("close ownedTab") }.count == 1)
        #expect(scripts.count == 3)
    }

    @Test func closeDoesNotWaitForOrCancelAnOrdinaryUncancelledOperation() async throws {
        let executor = SafariTransportMock(["PPOK\t47\n", "PPOK\tresult\n", "PPOK\t\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { Self.syntheticProcess })
        let window = try await safari.createWindow()
        await executor.setPaused(true)
        let pending = Task { try await safari.evaluate(script: "JSON.stringify({synthetic:true})", in: window) }
        for _ in 0..<100 {
            if await executor.scripts.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: SafariAutomationError.operationInProgress) { try await safari.close(window) }
        #expect(executor.cancellationCount == 0)
        await executor.release()
        _ = try await pending.value
        try await safari.close(window)
        #expect(await executor.scripts.count == 3)
    }

    @Test func creationRequiresAStableObservedSafariProcessIdentity() async {
        let executor = SafariTransportMock(["PPOK\t45\n"])
        let safari = SafariAutomation(executor: executor, isAvailable: { true }, processIdentity: { nil })
        await #expect(throws: SafariAutomationError.windowLost) { _ = try await safari.createWindow() }
    }

    private func waitUntilStarted(_ executor: SafariTransportMock) async throws {
        for _ in 0..<100 {
            if await !executor.scripts.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SafariAutomationError.timeout
    }
}

private actor SafariTransportMock: SafariScriptExecuting {
    private var results: [String]
    private(set) var scripts: [String] = []
    private var paused = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var syntheticError = false
    private nonisolated let cancellations = Mutex(0)
    nonisolated var cancellationCount: Int { cancellations.withLock { $0 } }
    init(_ results: [String]) { self.results = results }
    func setPaused(_ value: Bool) { paused = value }
    func release() { paused = false; waiting?.resume(); waiting = nil }
    func failWithSyntheticPrivateText() { syntheticError = true }
    func execute(_ script: String, timeout: Duration) async throws -> String {
        scripts.append(script)
        if paused { await withCheckedContinuation { waiting = $0 } }
        if syntheticError { throw NSError(domain: "synthetic-private-value", code: 0, userInfo: [NSLocalizedDescriptionKey: "synthetic-private-value"]) }
        guard !results.isEmpty else { throw SafariAutomationError.invalidResult }
        return results.removeFirst()
    }
    nonisolated func cancel() { cancellations.withLock { $0 += 1 } }
}

@Suite(.serialized) @MainActor struct SafariValidationTests {
    @Test func validationChecksOnlyOwnBlankWindowAndClosesIt() async {
        let safari = SafariValidationMock()
        #expect(await SafariValidation.run(safari: safari) == .passed)
        #expect(safari.actions == ["create", "url:88", "evaluate:88", "close:88"])
        #expect(safari.script?.contains("location.href !== 'about:blank'") == true)
        #expect(safari.script?.contains("marker.remove()") == true)
        #expect(safari.script?.contains("fetch(") == false)
        #expect(safari.script?.contains("cookie") == false)
    }

    @Test func validationRefusesChangedPageBeforeEvaluatingJavaScript() async {
        let safari = SafariValidationMock()
        safari.url = URL(string: "https://example.com")
        #expect(await SafariValidation.run(safari: safari) == .failed)
        #expect(safari.actions == ["create", "url:88", "close:88"])
        #expect(safari.script == nil)
    }

    @Test(arguments: [SafariAutomationError.permissionDenied, .javascriptDisabled, .unavailable, .invalidResult])
    func creationFailureReturnsOnlyFixedResultsAndNeverClosesAnotherWindow(error: SafariAutomationError) async {
        let safari = SafariValidationMock()
        safari.creationError = error
        let result = await SafariValidation.run(safari: safari)
        let expected: SafariValidationResult = switch error {
        case .permissionDenied: .permissionRequired
        case .javascriptDisabled: .javascriptDisabled
        case .unavailable: .unavailable
        default: .failed
        }
        #expect(result == expected)
        #expect(safari.actions == ["create"])
    }

    @Test func javascriptPermissionFailureStillClosesOnlyOwnedBlankWindow() async {
        let safari = SafariValidationMock()
        safari.evaluationError = .javascriptDisabled
        #expect(await SafariValidation.run(safari: safari) == .javascriptDisabled)
        #expect(safari.actions == ["create", "url:88", "evaluate:88", "close:88"])
    }

    @Test func failedSyntheticMarkerOrFailedCleanupCannotReportSuccess() async {
        let failedProbe = SafariValidationMock()
        failedProbe.response = "{\"ok\":false}"
        #expect(await SafariValidation.run(safari: failedProbe) == .failed)
        #expect(failedProbe.actions.last == "close:88")
        let failedClose = SafariValidationMock()
        failedClose.closeError = .ambiguousWindow
        #expect(await SafariValidation.run(safari: failedClose) == .failed)
    }
}

@MainActor private final class SafariValidationMock: SafariControlling {
    var actions: [String] = []
    var url = URL(string: "about:blank")
    var response = "{\"ok\":true}"
    var creationError: SafariAutomationError?
    var evaluationError: SafariAutomationError?
    var closeError: SafariAutomationError?
    var script: String?
    func createWindow() async throws -> SafariWindowHandle {
        actions.append("create")
        if let creationError { throw creationError }
        return SafariWindowHandle(id: 88)
    }
    func currentURL(in handle: SafariWindowHandle) async throws -> URL? { actions.append("url:\(handle.id)"); return url }
    func navigate(_ url: URL, in handle: SafariWindowHandle) async throws { Issue.record("Validation must not navigate to a website") }
    func evaluate(script: String, in handle: SafariWindowHandle) async throws -> String {
        actions.append("evaluate:\(handle.id)")
        self.script = script
        if let evaluationError { throw evaluationError }
        return response
    }
    func activate(_ handle: SafariWindowHandle) async throws { Issue.record("Validation must not activate another window") }
    func close(_ handle: SafariWindowHandle) async throws {
        actions.append("close:\(handle.id)")
        if let closeError { throw closeError }
    }
    func cancel() { actions.append("cancel") }
}

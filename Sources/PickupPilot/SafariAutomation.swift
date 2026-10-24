import AppKit
import Darwin
import Foundation
import Synchronization

/// An opaque reference to a window created for this checkout. Never includes a URL or page title.
struct SafariWindowHandle: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: Int
    var description: String { "Safari checkout window" }
    var debugDescription: String { description }
}

/// Window identifiers are scoped to this exact Safari launch, never to a later app instance.
struct SafariApplicationIdentity: Equatable, Sendable, CustomStringConvertible {
    let processIdentifier: Int32
    let launchDate: Date
    var description: String { "Safari application instance" }
}

enum SafariAutomationError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case unavailable, permissionDenied, javascriptDisabled, windowLost, ambiguousWindow
    case navigationChanged, timeout, cancelled, invalidResult, invalidURL, operationInProgress
    case operationFailed(code: Int?)

    var errorDescription: String? { description }
    var description: String {
        switch self {
        case .unavailable: "Safari is unavailable. Install Safari before starting checkout."
        case .permissionDenied: "Allow Pickup Pilot to control Safari in System Settings > Privacy & Security > Automation."
        case .javascriptDisabled: "Enable Allow JavaScript from Apple Events in Safari Settings > Developer > Automation."
        case .windowLost: "The dedicated Safari checkout window is closed or unavailable. Start a new checkout attempt."
        case .ambiguousWindow: "Safari could not identify a unique Pickup Pilot checkout tab."
        case .navigationChanged: "Safari's checkout document is changing."
        case .timeout: "Safari did not respond in time. Checkout stopped."
        case .cancelled: "Safari checkout was cancelled."
        case .invalidResult: "Safari returned an unsupported checkout response."
        case .invalidURL: "The Safari checkout destination is unsupported."
        case .operationInProgress: "A Safari checkout operation is already running."
        case .operationFailed(let code): code.map { "Safari could not complete the checkout operation (Apple event \($0))." } ?? "Safari could not complete the checkout operation."
        }
    }

    static func appleEvent(_ code: Int) -> Self {
        switch code {
        case -1743: .permissionDenied
        case 8, -27004: .javascriptDisabled
        case -600, -609: .unavailable
        case -1712: .timeout
        case -128: .cancelled
        case -27001: .windowLost
        case -1728, -27005: .navigationChanged
        case -27002: .ambiguousWindow
        case -27003: .invalidResult
        default: .operationFailed(code: code)
        }
    }
}

/// Keeps topology invalidation attached to a failed private helper response until the owning
/// transport consumes it. The public error remains the fixed, sanitized Apple-event reason.
private struct SafariTrackingFailure: Error, Sendable {
    let reason: SafariAutomationError
}

/// Main-actor API matches the checkout state machine; subprocess execution has its own actor.
@MainActor protocol SafariControlling: AnyObject {
    func createWindow() async throws -> SafariWindowHandle
    func expectNavigation(in handle: SafariWindowHandle) throws
    func confirmDocument(in handle: SafariWindowHandle)
    func navigate(_ url: URL, in handle: SafariWindowHandle) async throws
    func currentURL(in handle: SafariWindowHandle) async throws -> URL?
    func evaluate(script: String, in handle: SafariWindowHandle) async throws -> String
    func activate(_ handle: SafariWindowHandle) async throws
    func close(_ handle: SafariWindowHandle) async throws
    func cancel()
}

extension SafariControlling {
    func expectNavigation(in handle: SafariWindowHandle) throws {}
    func confirmDocument(in handle: SafariWindowHandle) {}
}

protocol SafariScriptExecuting: Sendable {
    func execute(_ script: String, timeout: Duration) async throws -> String
    func cancel()
}

/// Uses Safari's public AppleScript dictionary. Ownership resolution reads only an opaque marker
/// in eligible tabs; it never reads their content, cookies or browser settings.
@MainActor final class SafariAutomation: SafariControlling {
    private let executor: any SafariScriptExecuting
    private let isAvailable: @MainActor () -> Bool
    private let timeout: Duration
    private let processIdentity: @MainActor () -> SafariApplicationIdentity?
    private var ownedProcess: SafariApplicationIdentity?
    private var ownedWindowIDs: Set<Int> = []
    private var ownedWindowMarkers: [Int: UUID] = [:]
    private var recaptureEligibleWindowIDs: Set<Int> = []
    private var pendingNavigationDeadlines: [Int: ContinuousClock.Instant] = [:]
    private var generation: UInt64 = 0
    private var operationInFlight = false
    private var inFlightTask: Task<String, Error>?
    private var closingWindowIDs: Set<Int> = []

    init(executor: any SafariScriptExecuting = SafariScriptExecutor(), timeout: Duration = .seconds(15),
         isAvailable: @escaping @MainActor () -> Bool = { FileManager.default.fileExists(atPath: "/Applications/Safari.app") },
         processIdentity: @escaping @MainActor () -> SafariApplicationIdentity? = { SafariAutomation.runningSafariIdentity() }) {
        self.executor = executor
        self.timeout = timeout
        self.isAvailable = isAvailable
        self.processIdentity = processIdentity
    }

    func createWindow() async throws -> SafariWindowHandle {
        let before = processIdentity()
        if ownedProcess != nil, ownedProcess != before { invalidateOwnership() }
        let marker = UUID()
        let value = try await perform(SafariAppleScript.createWindow(marker: marker))
        guard let current = processIdentity(), before == nil || current == before else {
            invalidateOwnership()
            throw SafariAutomationError.windowLost
        }
        guard let id = Int(value), id > 0, !ownedWindowIDs.contains(id) else { throw SafariAutomationError.invalidResult }
        ownedProcess = current
        ownedWindowIDs.insert(id)
        ownedWindowMarkers[id] = marker
        recaptureEligibleWindowIDs.insert(id)
        return SafariWindowHandle(id: id)
    }

    func expectNavigation(in handle: SafariWindowHandle) throws {
        _ = try requireOwned(handle)
        guard recaptureEligibleWindowIDs.contains(handle.id), pendingNavigationDeadlines[handle.id] == nil else { return }
        // Repeated dispatches cannot prolong an unconfirmed navigation capability. A verified
        // document must consume it before another explicit navigation may receive a new one.
        pendingNavigationDeadlines[handle.id] = ContinuousClock.now.advanced(by: .seconds(15))
    }

    func confirmDocument(in handle: SafariWindowHandle) {
        pendingNavigationDeadlines.removeValue(forKey: handle.id)
    }

    func navigate(_ url: URL, in handle: SafariWindowHandle) async throws {
        _ = try requireOwned(handle)
        guard Self.isSupportedDestination(url) else { throw SafariAutomationError.invalidURL }
        try expectNavigation(in: handle)
        _ = try await perform(in: handle, script: script(in: handle, body: "set URL of ownedTab to \(SafariAppleScript.literal(url.absoluteString))\nreturn resultPrefix"))
    }

    func currentURL(in handle: SafariWindowHandle) async throws -> URL? {
        _ = try requireOwned(handle)
        let value = try await perform(in: handle, script: script(in: handle, allowNavigationRecapture: true, body: "set currentAddress to URL of ownedTab\nif currentAddress is missing value then return resultPrefix\nreturn resultPrefix & currentAddress"))
        if value.isEmpty { return nil }
        guard let url = URL(string: value), url.scheme != nil else { throw SafariAutomationError.invalidResult }
        return url
    }

    /// The caller supplies an expression that returns a string, normally JSON.stringify(...).
    /// Results stay in private pipes and memory; subprocess errors never echo the expression.
    func evaluate(script: String, in handle: SafariWindowHandle) async throws -> String {
        _ = try requireOwned(handle)
        return try await perform(in: handle, script: self.script(in: handle, allowNavigationRecapture: true, body: """
        set answerValue to do JavaScript \(SafariAppleScript.literal(script)) in ownedTab
        if class of answerValue is not text then error number -27003
        return resultPrefix & answerValue
        """))
    }

    func activate(_ handle: SafariWindowHandle) async throws {
        _ = try requireOwned(handle)
        _ = try await perform(in: handle, script: script(in: handle, body: "set current tab of ownedWindow to ownedTab\nset index of ownedWindow to 1\nactivate\nreturn resultPrefix"))
    }

    func close(_ handle: SafariWindowHandle) async throws {
        guard !closingWindowIDs.contains(handle.id) else { throw SafariAutomationError.operationInProgress }
        closingWindowIDs.insert(handle.id)
        defer { closingWindowIDs.remove(handle.id) }
        // UI cancellation is synchronous, while private helper termination unwinds asynchronously.
        // Wait only for an already-cancelled operation before dispatching this one close command.
        // Never retry a close whose Apple event may already have been delivered.
        if operationInFlight {
            guard inFlightTask?.isCancelled == true else { throw SafariAutomationError.operationInProgress }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while operationInFlight {
                guard !Task.isCancelled else { throw SafariAutomationError.cancelled }
                guard ContinuousClock.now < deadline else { throw SafariAutomationError.timeout }
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { throw SafariAutomationError.cancelled }
            }
        }
        _ = try requireOwned(handle)
        // A user may have added tabs or moved this tab to a shared window. Close only the
        // proven checkout tab, never the other tabs in its current container.
        _ = try await perform(in: handle, script: script(in: handle, body: "close ownedTab\nreturn resultPrefix"))
        ownedWindowIDs.remove(handle.id)
        ownedWindowMarkers.removeValue(forKey: handle.id)
        recaptureEligibleWindowIDs.remove(handle.id)
        pendingNavigationDeadlines.removeValue(forKey: handle.id)
    }

    func cancel() {
        generation &+= 1
        pendingNavigationDeadlines.removeAll()
        inFlightTask?.cancel()
        executor.cancel()
        // An Apple event already delivered to Safari cannot be retracted. Kill only our helper,
        // reject its late result and send no further commands; never close an unverified window.
    }

    private func requireOwned(_ handle: SafariWindowHandle) throws -> SafariApplicationIdentity {
        guard handle.id > 0, ownedWindowIDs.contains(handle.id), ownedWindowMarkers[handle.id] != nil, let ownedProcess else { throw SafariAutomationError.windowLost }
        guard processIdentity() == ownedProcess else {
            invalidateOwnership()
            throw SafariAutomationError.windowLost
        }
        return ownedProcess
    }

    private func invalidateOwnership() {
        ownedWindowIDs.removeAll()
        ownedWindowMarkers.removeAll()
        recaptureEligibleWindowIDs.removeAll()
        pendingNavigationDeadlines.removeAll()
        ownedProcess = nil
    }

    private func script(in handle: SafariWindowHandle, allowNavigationRecapture: Bool = false, body: String) throws -> String {
        _ = try requireOwned(handle)
        guard let marker = ownedWindowMarkers[handle.id] else { throw SafariAutomationError.windowLost }
        var recaptureSeconds: TimeInterval = 0
        if allowNavigationRecapture, recaptureEligibleWindowIDs.contains(handle.id), let deadline = pendingNavigationDeadlines[handle.id] {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            recaptureSeconds = max(0, min(15, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18))
        }
        return SafariAppleScript.inWindow(handle, marker: marker, allowNavigationRecapture: recaptureSeconds > 0,
                                         navigationRecaptureSeconds: recaptureSeconds, body: body)
    }

    // Native admission is checked on both sides of the command. Safari may quit between a
    // check and an Apple event; no response from a changed process is accepted. Document-ID
    // checks in the page adapter additionally guard every checkout write in the JS turn.
    private func perform(in handle: SafariWindowHandle, script: String) async throws -> String {
        let expectedProcess = try requireOwned(handle)
        do {
            let value = try await perform(script)
            guard try requireOwned(handle) == expectedProcess else { throw SafariAutomationError.windowLost }
            if value.hasPrefix("PPTRACK\t") {
                let fields = value.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, fields[1] == "0" || fields[1] == "1" else { throw SafariAutomationError.invalidResult }
                if fields[1] == "1" {
                    recaptureEligibleWindowIDs.remove(handle.id)
                    pendingNavigationDeadlines.removeValue(forKey: handle.id)
                }
                return String(fields[2])
            }
            return value
        } catch {
            _ = try requireOwned(handle)
            if let failure = error as? SafariTrackingFailure {
                recaptureEligibleWindowIDs.remove(handle.id)
                pendingNavigationDeadlines.removeValue(forKey: handle.id)
                throw failure.reason
            }
            if let error = error as? SafariAutomationError, error == .windowLost || error == .ambiguousWindow {
                recaptureEligibleWindowIDs.remove(handle.id)
                pendingNavigationDeadlines.removeValue(forKey: handle.id)
            }
            throw error
        }
    }

    private static func runningSafariIdentity() -> SafariApplicationIdentity? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
        guard running.count == 1, let safari = running.first, !safari.isTerminated, let launchDate = safari.launchDate else { return nil }
        return SafariApplicationIdentity(processIdentifier: safari.processIdentifier, launchDate: launchDate)
    }

    private func perform(_ script: String) async throws -> String {
        guard isAvailable() else { throw SafariAutomationError.unavailable }
        guard !operationInFlight else { throw SafariAutomationError.operationInProgress }
        guard !Task.isCancelled else { throw SafariAutomationError.cancelled }
        operationInFlight = true
        defer { operationInFlight = false; inFlightTask = nil }
        let currentGeneration = generation
        let executor = executor, timeout = timeout
        // Retain the child so synchronous UI disarm cancels it even before the executor actor
        // starts. Its cancellation bit bridges that admission race; generation rejects late output.
        let task = Task { try await executor.execute(script, timeout: timeout) }
        inFlightTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard currentGeneration == generation, !Task.isCancelled else { throw SafariAutomationError.cancelled }
            return try SafariAppleScript.decode(result)
        } catch {
            guard currentGeneration == generation, !Task.isCancelled else { throw SafariAutomationError.cancelled }
            if let trackingFailure = error as? SafariTrackingFailure { throw trackingFailure }
            if let safeError = error as? SafariAutomationError { throw safeError }
            throw SafariAutomationError.operationFailed(code: nil)
        }
    }

    static func isSupportedDestination(_ url: URL) -> Bool {
        let value = url.absoluteString
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), url.user == nil, url.password == nil else { return false }
        if value == "about:blank" { return true }
        if url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
    }
}

/// The only generated source is passed through stdin. No script, URL or form data enters argv/files.
enum SafariAppleScript {
    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func wrap(_ body: String, tracksOwnership: Bool = false) -> String {
        let trackingSetup = tracksOwnership ? "set recaptureDisabled to false" : ""
        let trackingFailure = tracksOwnership ? "if recaptureDisabled then return \"PPERR\\t\" & errorNumber & \"\\tPPTRACK\\t1\"" : ""
        return """
        \(trackingSetup)
        try
            with timeout of 12 seconds
                tell application "/Applications/Safari.app"
                    \(body)
                end tell
            end timeout
        on error errorText number errorNumber
            if errorText contains "JavaScript" and errorText contains "Apple Events" then set errorNumber to -27004
            \(trackingFailure)
            return "PPERR\\t" & errorNumber
        end try
        """
    }

    static var createWindow: String { createWindow(marker: UUID()) }

    static func createWindow(marker: UUID) -> String {
        // Enumerate identifiers only. Diffing identifiers avoids assuming the user's front window
        // is ours if another application/user opens a window while Safari handles make document.
        let source = "(() => { if (location.href !== 'about:blank') return false; window.name = '\(markerName(marker))'; return window.name === '\(markerName(marker))'; })()"
        let markDocument = """
            try
                set markedDocument to do JavaScript \(literal(source)) in tab 1 of ownedWindow
                if markedDocument is not true then error number -27003
            on error markingErrorText number markingErrorNumber
                -- No handle has been returned yet. Clean up only the newly captured,
                -- still-empty window; a changed document or user-added tab stays open.
                try
                    set cleanupMatches to every window whose id is createdID
                    if (count of cleanupMatches) is 1 then
                        set cleanupWindow to window id createdID
                        if (count of tabs of cleanupWindow) is 1 then
                            if URL of tab 1 of cleanupWindow is "about:blank" then close cleanupWindow
                        end if
                    end if
                end try
                error markingErrorText number markingErrorNumber
            end try
            """
        return wrap("""
        set previousIDs to id of every window
        make new document with properties {URL:"about:blank"}
        set createdIDs to {}
        repeat with candidateWindow in every window
            set candidateID to id of candidateWindow
            if candidateID is not in previousIDs then set end of createdIDs to candidateID
        end repeat
        if (count of createdIDs) is not 1 then error number -27002
        set createdID to item 1 of createdIDs
        set ownedWindow to window id createdID
        if (count of tabs of ownedWindow) is not 1 then error number -27002
        if URL of tab 1 of ownedWindow is not "about:blank" then error number -27003
        \(markDocument)
        return "PPOK\\t" & createdID
        """)
    }

    static func inWindow(_ handle: SafariWindowHandle, marker: UUID = UUID(), allowNavigationRecapture: Bool = false,
                         navigationRecaptureSeconds: TimeInterval = 15, body: String) -> String {
        let documentGuard = """
        if (location.href !== 'about:blank' &&
            (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
             location.username || location.password || (location.port && location.port !== '443'))) return false;
        """
        let name = markerName(marker)
        let probe = "(() => { \(documentGuard) return window.name === '\(name)'; })()"
        let nativeEligibility = """
        set candidateEligible to false
        if candidateAddress is not missing value then
            if candidateAddress is "about:blank" then
                set candidateEligible to true
            else if candidateAddress starts with "https://" and (length of candidateAddress) is greater than 8 then
                set savedDelimiters to AppleScript's text item delimiters
                try
                    set AppleScript's text item delimiters to {"/", "?", "#"}
                    set candidateAuthority to text item 1 of (text 9 thru -1 of candidateAddress)
                    set AppleScript's text item delimiters to savedDelimiters
                on error addressErrorText number addressErrorNumber
                    set AppleScript's text item delimiters to savedDelimiters
                    error addressErrorText number addressErrorNumber
                end try
                if candidateAuthority ends with ":443" then
                    if (length of candidateAuthority) is greater than 4 then
                        set candidateAuthority to text 1 thru -5 of candidateAuthority
                    else
                        set candidateAuthority to ""
                    end if
                end if
                if candidateAuthority does not contain "@" then
                    if candidateAuthority is "apple.com" or candidateAuthority ends with ".apple.com" then set candidateEligible to true
                end if
            end if
        end if
        """
        let probeCandidate = """
        set inspectedTabs to inspectedTabs + 1
        if inspectedTabs is greater than 256 then error number -27002
        try
            set candidateAddress to URL of candidateTab
            \(nativeEligibility)
            if candidateEligible then
                set markerMatchesTab to do JavaScript \(literal(probe)) in candidateTab
                if markerMatchesTab is true then
                    if searchingOriginalWindow is false then set recaptureDisabled to true
                    set markerMatches to markerMatches + 1
                    set ownedWindow to contents of candidateWindow
                    set ownedTab to contents of candidateTab
                end if
            end if
        on error errorText number errorNumber
            if errorNumber is -1728 or errorNumber is -27005 then
                set hadTransientFailure to true
            else
                error number errorNumber
            end if
        end try
        """
        let recaptureSource = """
        (() => {
          \(documentGuard)
          if (window.name.startsWith('PickupPilotCheckout:') && window.name !== '\(name)') return false;
          window.name = '\(name)';
          return window.name === '\(name)';
        })()
        """
        let recaptureSeconds = navigationRecaptureSeconds.isFinite ? max(0, min(15, navigationRecaptureSeconds)) : 0
        let recoveryDeadline = allowNavigationRecapture && recaptureSeconds > 0
            ? "set navigationRecoveryDeadline to (current date) + \(recaptureSeconds)"
            : ""
        let scopedRecapture = allowNavigationRecapture && recaptureSeconds > 0 ? """
        if markerMatches is 0 and recaptureDisabled is false and hadTransientFailure is false and (current date) is less than navigationRecoveryDeadline then
            -- Only explicit, still-pending navigation may replace a name cleared by WebKit.
            -- The original created window must remain a single eligible document, and any
            -- previously observed tab sharing/movement permanently disables this path.
            set recoveryWindows to every window whose id is \(handle.id)
            if (count of recoveryWindows) is 1 then
                set recoveryWindow to window id \(handle.id)
                if (count of tabs of recoveryWindow) is 1 then
                    set recoveryTab to tab 1 of recoveryWindow
                    set candidateAddress to URL of recoveryTab
                    \(nativeEligibility)
                    if candidateEligible and (current date) is less than navigationRecoveryDeadline then
                        set recoveredDocument to do JavaScript \(literal(recaptureSource)) in recoveryTab
                        if recoveredDocument is true then
                            set ownedWindow to recoveryWindow
                            set ownedTab to recoveryTab
                            set markerMatches to 1
                        end if
                    end if
                end if
            end if
        end if
        """ : ""
        // Start with the original window, which remains proof even if another tab copies its
        // name. Only search elsewhere after losing that marker. Native URL eligibility keeps
        // marker probes out of unrelated HTTPS pages; the DOM guard remains authoritative.
        // No command is redispatched if Safari invalidates a reference during the body.
        return wrap("""
        set ownedWindow to missing value
        set ownedTab to missing value
        set markerMatches to 0
        set recaptureDisabled to false
        set hadTransientFailure to false
        set inspectedTabs to 0
        set searchingOriginalWindow to true
        \(recoveryDeadline)
        set matchingWindows to every window whose id is \(handle.id)
        if (count of matchingWindows) is greater than 1 then error number -27002
        if (count of matchingWindows) is 1 then
            set candidateWindow to window id \(handle.id)
            if (count of tabs of candidateWindow) is not 1 then set recaptureDisabled to true
            repeat with candidateTab in tabs of candidateWindow
                \(probeCandidate)
            end repeat
        end if
        if markerMatches is greater than 1 then error number -27002
        if markerMatches is 0 then
            set searchingOriginalWindow to false
            if (count of windows) is greater than 64 then error number -27002
            repeat with candidateWindow in every window
                if id of candidateWindow is not \(handle.id) then
                    repeat with candidateTab in tabs of candidateWindow
                        \(probeCandidate)
                    end repeat
                end if
            end repeat
        end if
        if markerMatches is greater than 1 then error number -27002
        if markerMatches is 1 then
            if id of ownedWindow is not \(handle.id) then set recaptureDisabled to true
        end if
        \(scopedRecapture)
        if markerMatches is 0 then
            -- An original window can now contain somebody else's tab. Never reclaim an
            -- unmarked document without the scoped navigation capability above. Cleanup
            -- never receives that capability. Higher layers may reconnect before submission.
            if hadTransientFailure then error number -27005
            error number -27001
        end if
        set stillOwned to do JavaScript \(literal(probe)) in ownedTab
        if stillOwned is not true then error number -27005
        set resultPrefix to "PPOK\\tPPTRACK\\t0\\t"
        if recaptureDisabled then set resultPrefix to "PPOK\\tPPTRACK\\t1\\t"
        \(body)
        """, tracksOwnership: true)
    }

    private static func markerName(_ marker: UUID) -> String {
        // UUID's fixed ASCII representation cannot inject JavaScript or AppleScript syntax.
        "PickupPilotCheckout:" + marker.uuidString
    }

    static func decode(_ output: String) throws -> String {
        // osascript adds exactly one record terminator; preserve the value itself.
        var value = output
        if value.utf8.last == 10 { value = String(decoding: value.utf8.dropLast(), as: UTF8.self) }
        if value.hasPrefix("PPOK\t") { return String(value.dropFirst(5)) }
        if value.hasPrefix("PPERR\t") {
            let fields = value.dropFirst(6).split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count == 1, let code = Int(fields[0]) { throw SafariAutomationError.appleEvent(code) }
            if fields.count == 3, let code = Int(fields[0]), fields[1] == "PPTRACK", fields[2] == "1" {
                throw SafariTrackingFailure(reason: SafariAutomationError.appleEvent(code))
            }
        }
        throw SafariAutomationError.invalidResult
    }
}

/// The actor owns admission; a small Mutex protects only synchronous helper cancellation/launch.
/// Foundation Process and its pipes are confined to the detached blocking operation, except the
/// process handle used under this lock to terminate that exact owned child. No unchecked Sendable.
actor SafariScriptExecutor: SafariScriptExecuting {
    private nonisolated let control = SafariProcessControl()
    private var running = false

    func execute(_ script: String, timeout: Duration) async throws -> String {
        guard !running else { throw SafariAutomationError.operationInProgress }
        guard !Task.isCancelled else { throw SafariAutomationError.cancelled }
        running = true
        defer { running = false }
        let token = control.token()
        let control = control
        // Pipe I/O and waitUntilExit are blocking Foundation APIs; keep them off every actor.
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.executeBlocking(script, timeout: timeout, token: token, control: control)
            }.value
        } onCancel: { control.cancel() }
    }

    nonisolated func cancel() { control.cancel() }

    private nonisolated static func executeBlocking(_ script: String, timeout: Duration, token: UInt64, control: SafariProcessControl) throws -> String {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript", "-"]
        process.standardInput = input
        process.standardOutput = output
        // A compiler/runtime diagnostic may echo a source fragment, so never capture or forward it.
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try control.launch(process, token: token)
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            control.finish(process, token: token)
        }
        let seconds = max(0.001, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        let deadline = DispatchWorkItem { control.stop(process, token: token, reason: .timeout) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: deadline)
        defer { deadline.cancel() }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try input.fileHandleForWriting.close()
            var result = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard result.count + chunk.count <= 4_194_304 else {
                    control.stop(process, token: token, reason: .invalidResult)
                    throw SafariAutomationError.invalidResult
                }
                result.append(chunk)
            }
            process.waitUntilExit()
            try control.check(token: token)
            guard process.terminationStatus == 0 else { throw SafariAutomationError.operationFailed(code: nil) }
            guard let value = String(data: result, encoding: .utf8) else { throw SafariAutomationError.invalidResult }
            return value
        } catch {
            control.stop(process, token: token, reason: .operationFailed(code: nil))
            try control.check(token: token)
            if let safeError = error as? SafariAutomationError { throw safeError }
            throw SafariAutomationError.operationFailed(code: nil)
        }
    }
}

private final class SafariProcessControl: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var process: Process?
        var failure: SafariAutomationError?
    }
    private let state = Mutex(State())
    func token() -> UInt64 { state.withLock { $0.generation } }
    func launch(_ process: Process, token: UInt64) throws {
        try state.withLock { state in
            guard state.generation == token else { throw SafariAutomationError.cancelled }
            state.failure = nil
            do { try process.run() } catch { throw SafariAutomationError.unavailable }
            state.process = process
        }
    }
    func cancel() {
        let stopped = state.withLock { state -> Process? in
            state.generation &+= 1
            state.failure = .cancelled
            if let process = state.process, process.isRunning { process.terminate(); return process }
            return nil
        }
        if let stopped { forceKillIfStillOwned(stopped) }
    }
    func stop(_ process: Process, token: UInt64, reason: SafariAutomationError) {
        state.withLock { state in
            guard state.generation == token, state.process === process else { return }
            if state.failure == nil { state.failure = reason }
            if process.isRunning { process.terminate() }
        }
        // terminate sends SIGTERM; bound an unresponsive owned child without touching Safari.
        forceKillIfStillOwned(process)
    }
    private func forceKillIfStillOwned(_ process: Process) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [self] in
            state.withLock { state in
                guard state.process === process, process.isRunning else { return }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
    func check(token: UInt64) throws {
        try state.withLock { state in
            guard state.generation == token else { throw SafariAutomationError.cancelled }
            if let failure = state.failure { throw failure }
        }
    }
    func finish(_ process: Process, token: UInt64) {
        state.withLock { state in
            if state.process === process { state.process = nil }
        }
    }
}

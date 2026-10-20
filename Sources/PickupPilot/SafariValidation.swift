import Foundation

/// Fixed output suitable for an explicit local validation receipt; never contains browser data.
enum SafariValidationResult: String, Sendable, CustomStringConvertible {
    case passed, permissionRequired, javascriptDisabled, unavailable, failed
    var description: String { rawValue }
}

/// Called only by the explicit --ui-preview --validate-safari path. It uses a newly created blank
/// window, checks a synthetic DOM marker, and closes only that captured owned window.
@MainActor enum SafariValidation {
    static func run(safari: any SafariControlling = SafariAutomation()) async -> SafariValidationResult {
        var ownedWindow: SafariWindowHandle?
        var result: SafariValidationResult = .failed
        do {
            let window = try await safari.createWindow()
            ownedWindow = window
            guard try await safari.currentURL(in: window)?.absoluteString == "about:blank" else {
                throw SafariAutomationError.invalidResult
            }
            let probe = try await safari.evaluate(script: """
            (() => {
                if (location.href !== 'about:blank' || !document.body) return JSON.stringify({ok:false});
                const marker = document.createElement('div');
                marker.dataset.pickupPilotValidation = 'synthetic';
                marker.textContent = 'Pickup Pilot local Safari validation';
                document.body.appendChild(marker);
                const ok = marker.isConnected && marker.dataset.pickupPilotValidation === 'synthetic'
                    && marker.textContent === 'Pickup Pilot local Safari validation';
                marker.remove();
                return JSON.stringify({ok});
            })()
            """, in: window)
            guard probe == "{\"ok\":true}" else { throw SafariAutomationError.invalidResult }
            result = .passed
        } catch SafariAutomationError.permissionDenied { result = .permissionRequired }
        catch SafariAutomationError.javascriptDisabled { result = .javascriptDisabled }
        catch SafariAutomationError.unavailable { result = .unavailable }
        catch { result = .failed }
        if let ownedWindow {
            do { try await safari.close(ownedWindow) }
            catch { if result == .passed { result = .failed } }
        }
        return result
    }
}

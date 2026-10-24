import AppKit
import JavaScriptCore
import Testing
@testable import PickupPilot

/// Compiles generated AppleScript and executes only its isolated ownership predicate.
/// No script is sent to Safari and no browser, checkout or profile is opened.
@Suite(.serialized) @MainActor struct SafariTrackingScriptTests {
    private let marker = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!

    @Test func generatedTrackingActionsCompileWithoutExecutingSafari() throws {
        let actions = [
            "set currentAddress to URL of ownedTab\nreturn \"PPOK\\t\" & currentAddress",
            "set URL of ownedTab to \"https://www.apple.com/ca/shop/bag\"\nreturn \"PPOK\\t\"",
            "set answerValue to do JavaScript \"JSON.stringify({synthetic:true})\" in ownedTab\nreturn \"PPOK\\t\" & answerValue",
            "set current tab of ownedWindow to ownedTab\nset index of ownedWindow to 1\nreturn \"PPOK\\t\"",
            "close ownedTab\nreturn \"PPOK\\t\""
        ]
        let scripts = [SafariAppleScript.createWindow(marker: marker),
                       SafariAppleScript.inWindow(SafariWindowHandle(id: 77), marker: marker, allowNavigationRecapture: true,
                                                  body: "return resultPrefix")] + actions.map {
            SafariAppleScript.inWindow(SafariWindowHandle(id: 77), marker: marker, body: $0)
        }
        for source in scripts {
            let script = try #require(NSAppleScript(source: source))
            var diagnostic: NSDictionary?
            #expect(script.compileAndReturnError(&diagnostic), "Generated AppleScript must compile")
        }
    }

    @Test(arguments: ["about:blank", "https://www.apple.com/ca/shop/bag", "https://secure6.store.apple.com/ca/shop/checkout"])
    func ownershipPredicateRequiresItsExactMarkerOnAllowedDocuments(_ address: String) throws {
        let source = SafariAppleScript.inWindow(SafariWindowHandle(id: 77), marker: marker, body: "return \"PPOK\\t\"")
        let regex = try NSRegularExpression(pattern: #"set markerMatchesTab to do JavaScript ("(?:[^"\\]|\\.)*")"#)
        let match = try #require(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let range = try #require(Range(match.range(at: 1), in: source))
        let predicate = try JSONDecoder().decode(String.self, from: Data(source[range].utf8))
        let context = try #require(JSContext())
        let url = try #require(URLComponents(string: address))
        context.setObject(["href": address, "protocol": (url.scheme ?? "") + ":", "hostname": url.host ?? "",
                           "username": "", "password": "", "port": ""], forKeyedSubscript: "location" as NSString)
        let name = "PickupPilotCheckout:" + marker.uuidString
        context.setObject(["name": name], forKeyedSubscript: "window" as NSString)
        #expect(context.evaluateScript(predicate)?.toBool() == true)
        context.evaluateScript("window.name='unrelated';")
        #expect(context.evaluateScript(predicate)?.toBool() == false)
        #expect(context.evaluateScript("window.name")?.toString() == "unrelated")
        context.evaluateScript("window.name='\(name)';location.hostname='apple.com.example.invalid';location.href='https://apple.com.example.invalid';")
        #expect(context.evaluateScript(predicate)?.toBool() == false)
        #expect(context.exception == nil)
    }

    @Test func scopedNavigationRecaptureCannotOverwriteAnotherAttemptsMarker() throws {
        let source = SafariAppleScript.inWindow(SafariWindowHandle(id: 77), marker: marker,
                                               allowNavigationRecapture: true, body: "return resultPrefix")
        let regex = try NSRegularExpression(pattern: #"set recoveredDocument to do JavaScript ("(?:[^"\\]|\\.)*")"#)
        let match = try #require(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        let range = try #require(Range(match.range(at: 1), in: source))
        let predicate = try JSONDecoder().decode(String.self, from: Data(source[range].utf8))
        let context = try #require(JSContext())
        context.setObject(["href": "https://secure6.store.apple.com/ca/shop/checkout", "protocol": "https:",
                           "hostname": "secure6.store.apple.com", "username": "", "password": "", "port": ""],
                          forKeyedSubscript: "location" as NSString)
        context.setObject(["name": "PickupPilotCheckout:OTHER-ATTEMPT"], forKeyedSubscript: "window" as NSString)
        #expect(context.evaluateScript(predicate)?.toBool() == false)
        #expect(context.evaluateScript("window.name")?.toString() == "PickupPilotCheckout:OTHER-ATTEMPT")
        context.evaluateScript("window.name='';")
        #expect(context.evaluateScript(predicate)?.toBool() == true)
        #expect(context.evaluateScript("window.name")?.toString() == "PickupPilotCheckout:" + marker.uuidString)
        context.evaluateScript("window.name='';location.hostname='apple.com.example.invalid';")
        #expect(context.evaluateScript(predicate)?.toBool() == false)
        #expect(context.evaluateScript("window.name")?.toString() == "")
        #expect(context.exception == nil)
    }
}

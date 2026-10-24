import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import PickupPilot

/// A local CSP-denied document records its viewport during bootstrap. There are
/// no remote resources, checkout fields, cookies, or order actions in this fixture.
@Suite(.serialized) @MainActor struct CheckoutViewportTests {
    private func fixture(_ page: WKAppleCheckoutPage) async throws -> String {
        let marker = UUID().uuidString
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'">
        <style>html,body{margin:0;padding:0}</style>
        <script>window.__viewportFixture={marker:'\(marker)',width:innerWidth,height:innerHeight};</script>
        </head><body><p>Synthetic viewport fixture</p></body></html>
        """
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com/ca/shop/bag")!)
        for _ in 0..<150 {
            let value = try? await page.webView.callAsyncJavaScript(
                "return document.readyState==='complete'?window.__viewportFixture?.marker||'':'';", in: nil, contentWorld: .page)
            if value as? String == marker, !page.webView.isLoading { return marker }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ViewportFixtureError.documentDidNotLoad
    }

    private func dimensions(_ page: WKAppleCheckoutPage, initial: Bool = false) async throws -> [Int] {
        let script = initial ? "return [window.__viewportFixture.width,window.__viewportFixture.height];" : "return [innerWidth,innerHeight];"
        return try #require(try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page) as? [Int])
    }

    private func settle(_ page: WKAppleCheckoutPage, in controller: NSViewController, size: NSSize) async throws {
        var viewport: [Int] = []
        for _ in 0..<100 {
            controller.view.window?.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            viewport = try await dimensions(page)
            if viewport == [Int(size.width), Int(size.height)] { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ViewportFixtureError.hostDidNotResize(expected: size, viewport: viewport,
                                                    webView: page.webView.bounds.size,
                                                    host: controller.view.bounds.size,
                                                    content: controller.view.window?.contentView?.bounds.size)
    }

    @Test func initialDocumentHasADesktopViewportBeforeWindowAttachment() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        #expect(page.webView.window == nil && page.webView.superview == nil)
        #expect(page.webView.bounds.size == NSSize(width: 980, height: 760))

        _ = try await fixture(page)

        #expect(page.webView.window == nil && page.webView.superview == nil)
        #expect(try await dimensions(page, initial: true) == [980, 760])
        #expect(try await dimensions(page) == [980, 760])
        #expect(!page.webView.configuration.websiteDataStore.isPersistent)
    }

    @Test func swiftUIHostingAndWindowResizingReplaceOnlyTheInitialViewport() async throws {
        _ = NSApplication.shared
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let marker = try await fixture(page)
        let controller = NSHostingController(rootView: CheckoutWebView(webView: page.webView)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        controller.sizingOptions = []
        let initialSize = NSSize(width: 720, height: 560)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: initialSize),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: initialSize)
        window.orderFront(nil)
        defer { window.close() }
        try await settle(page, in: controller, size: initialSize)
        #expect(page.webView.window === window)

        let resized = NSSize(width: 1120, height: 840)
        window.setContentSize(resized)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        // AppKit's available content area can exclude window chrome. Compare the
        // DOM and hosted view to that independently measured area, not the request.
        let available = try #require(window.contentView?.bounds.size)
        #expect(available.width == resized.width)
        #expect(available.height > initialSize.height)
        try await settle(page, in: controller, size: available)
        #expect(page.webView.bounds.size == available)
        #expect(controller.view.bounds.size == available)
        #expect(try await dimensions(page, initial: true) == [980, 760])
        let currentMarker = try await page.webView.callAsyncJavaScript("return window.__viewportFixture.marker;", in: nil, contentWorld: .page)
        #expect(currentMarker as? String == marker)
    }
}

private enum ViewportFixtureError: Error {
    case documentDidNotLoad
    case hostDidNotResize(expected: NSSize, viewport: [Int], webView: NSSize, host: NSSize, content: NSSize?)
}

import Foundation
import Testing
@testable import PilotCore

@Test func unauthenticatedInventoryFailureNeverRequestsSignIn() {
    let message = AppleServiceError.authenticationRequired.localizedDescription
    #expect(message.contains("guest request") && message.contains("HTTP 401"))
    #expect(!message.contains("Open the checkout") && !message.contains("sign in") && !message.contains("continue"))
}

private actor InventoryTestTransport: HTTPTransport {
    let response: HTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: HTTPResponse) { self.response = response }
    func data(for request: URLRequest) async throws -> HTTPResponse { requests.append(request); return response }
}
private func testVariant(_ id: String = "TEST-CA/A", market: Market = .ca) -> ProductVariant {
    ProductVariant(id: id, name: "iPhone Duo 256GB Night Sky", storage: "256GB", color: "Night Sky",
                   productURL: market.productBaseURL.appendingPathComponent("7.6-inch-display-256gb-night-sky"))
}
private func pickupJSON(display: String = "available", search: Bool = true, selection: Bool = true,
                        eligible: Bool = true, extraPart: String = "", duplicate: Bool = false) -> Data {
    let store = """
    {"storeNumber":"R121","storeName":"Eaton Centre","country":"CA","storelatitude":43.653,"storelongitude":-79.3804,
     "city":"Toronto","state":"ON","address":{"address2":"220 Yonge Street","postalCode":"M5B 2H1"},
     "retailStore":{"availableNow":true},"partsAvailability":{"TEST-CA/A":{
       "storePickEligible":\(eligible),"pickupDisplay":"\(display)","pickupSearchQuote":"Pickup quote",
       "messageTypes":{"regular":{"storeSearchEnabled":\(search),"storeSelectionEnabled":\(selection),"storePickupQuote":"Today"}}}\(extraPart)}}
    """
    return Data("{\"body\":{\"stores\":[\(store)\(duplicate ? "," + store : "")]}}".utf8)
}
private func catalogHTML(market: Market = .ca, sku: String = "TEST-CA/A", currency: String = "CAD", family: String = "iphoneduo",
                         capacity: String = "256gb", color: String = "nightsky", addProducts: String = "", link: String? = nil) -> Data {
    let href = link ?? market.productBaseURL.appendingPathComponent("7.6-inch-display-\(capacity)-night-sky").absoluteString
    return Data("""
    <a href="\(href)">Select product</a><script>window.PRODUCT_SELECTION_BOOTSTRAP = {
    productSelectionData: {"products":[{"partNumber":"\(sku)","familyType":"\(family)","dimensionCapacity":"\(capacity)","dimensionColor":"\(color)"}\(addProducts)],
    "displayValues":{"dimensionColor":{"nightsky":{"value":"Night Sky"},"variantOrder":["nightsky"],"title":{"unused":true}},
    "prices":{"test":{"partNumber":"\(sku)","priceCurrency":"\(currency)"}}}}};
    </script>
    """.utf8)
}

@Test func marketsHaveDistinctStorefrontsAndPhysicalCountryCodes() throws {
    #expect(Market(countryCode: " GB ") == .uk)
    #expect(Market(countryCode: "CA") == .ca)
    #expect(Market(countryCode: "ZZ") == nil)
    #expect(Market.us.storefrontPath == "")
    #expect(Market.uk.countryCode == "GB")
    for market in Market.allCases {
        #expect(!market.displayName.isEmpty)
        #expect(market.currencyCode.count == 3)
        #expect(market.productBaseURL.host == "www.apple.com")
        #expect(Market(countryCode: market.countryCode) == market)
        #expect(market.id == market.rawValue)
        #expect(try JSONDecoder().decode(Market.self, from: JSONEncoder().encode(market)) == market)
    }
}
@Test func coordinatesRankRealStoresAndHandleMissingCoordinates() {
    let toronto = Coordinate(latitude: 43.65, longitude: -79.38)
    let london = Coordinate(latitude: 51.51, longitude: -0.14)
    #expect(abs(toronto.distanceKilometers(to: london) - 5_711) < 20)
    #expect(toronto.distanceKilometers(to: toronto) == 0)
    #expect(!Coordinate(latitude: .nan, longitude: 0).isValid)
    #expect(!Coordinate(latitude: 91, longitude: 0).isValid)
    #expect(!Coordinate(latitude: 0, longitude: 181).isValid)
    let near = RetailStore(id: "near", name: "Nearby", latitude: 43.653, longitude: -79.3804)
    let far = RetailStore(id: "far", name: "Far", latitude: 51.51, longitude: -0.14)
    let missing = RetailStore(id: "missing", name: "Missing")
    let invalid = RetailStore(id: "invalid", name: "A invalid", latitude: 200, longitude: 0)
    #expect(invalid.coordinate == nil)
    #expect(LocationResolver.rank([far, missing, near], near: toronto).map(\.id) == ["near", "far", "missing"])
    #expect(LocationResolver.rank([missing, invalid], near: toronto).map(\.id) == ["invalid", "missing"])
    #expect(LocationResolver.rank([far, near], near: nil) == [far, near])
    #expect(LocationResolver.rank([far, near], near: Coordinate(latitude: .infinity, longitude: 0)) == [far, near])
}
@Test func locationResolutionUsesPhysicalFixAndHonorsManualOverride() {
    let now = Date(timeIntervalSince1970: 1_000)
    let coordinate = Coordinate(latitude: 43.65, longitude: -79.38)
    let fix = LocationFix(coordinate: coordinate, countryCode: "CA", postalCode: " M5B 2H1 ", timestamp: now, horizontalAccuracy: 10)
    #expect(LocationResolver.resolve(authorization: .allowed, fix: fix, now: now) ==
        .ready(LocationSelection(market: .ca, query: "M5B 2H1", coordinate: coordinate, source: .physical)))
    let manual = LocationSelection(market: .uk, query: " SW1A 1AA ", source: .physical)
    #expect(LocationResolver.resolve(manual: manual, authorization: .denied, fix: fix, now: now) ==
        .ready(LocationSelection(market: .uk, query: "SW1A 1AA", source: .manual)))
    #expect(LocationResolver.requiresSelectionReset(from: .ca, to: .uk))
    #expect(!LocationResolver.requiresSelectionReset(from: .ca, to: .ca))
    for authorization in [LocationAuthorization.denied, .restricted, .notDetermined] {
        guard case .manualRequired = LocationResolver.resolve(authorization: authorization, fix: fix, now: now) else { Issue.record("Expected fallback"); return }
    }
    guard case .manualRequired = LocationResolver.resolve(authorization: .allowed, now: now) else { Issue.record("Missing fix must prompt"); return }
}
@Test func locationResolutionRejectsInvalidStaleAndUnsupportedFixes() {
    let now = Date(timeIntervalSince1970: 1_000)
    let coordinate = Coordinate(latitude: 43.65, longitude: -79.38)
    for fix in [
        LocationFix(coordinate: coordinate, countryCode: "CA", postalCode: "M5B", timestamp: now.addingTimeInterval(-301), horizontalAccuracy: 1),
        LocationFix(coordinate: coordinate, countryCode: "CA", postalCode: "M5B", timestamp: now.addingTimeInterval(61), horizontalAccuracy: 1),
        LocationFix(coordinate: coordinate, countryCode: "CA", postalCode: "M5B", timestamp: now, horizontalAccuracy: -1),
        LocationFix(coordinate: Coordinate(latitude: 100, longitude: 0), countryCode: "CA", postalCode: "M5B", timestamp: now, horizontalAccuracy: 1),
        LocationFix(coordinate: coordinate, countryCode: "CA", timestamp: now, horizontalAccuracy: 1)
    ] {
        guard case .manualRequired = LocationResolver.resolve(authorization: .allowed, fix: fix, now: now) else { Issue.record("Expected manual fallback"); return }
    }
    #expect(LocationResolver.resolve(authorization: .allowed, fix: LocationFix(coordinate: coordinate, countryCode: "ZZ", timestamp: now, horizontalAccuracy: 1), now: now) == .unsupportedCountry("ZZ"))
    for manual in [LocationSelection(market: .ca, query: " ", source: .manual),
                   LocationSelection(market: .ca, query: "M5B", coordinate: Coordinate(latitude: 0, longitude: 200), source: .manual)] {
        guard case .manualRequired = LocationResolver.resolve(manual: manual, authorization: .allowed) else { Issue.record("Expected manual fallback"); return }
    }
}
@Test func parserRequiresProductSpecificSelectionAndNeverUsesGenericStock() throws {
    let available = try InventoryParser.parse(pickupJSON(), variantIDs: ["TEST-CA/A"])
    #expect(available.availability[0].state == .available)
    #expect(available.availability[0].message == "Today")
    #expect(available.stores[0].address == "220 Yonge Street, Toronto, ON, M5B 2H1")
    #expect(try JSONDecoder().decode(InventorySnapshot.self, from: JSONEncoder().encode(available)) == available)
    for display in ["unavailable", "default", "ineligible", "notAvailable"] {
        #expect(try InventoryParser.parse(pickupJSON(display: display), variantIDs: ["TEST-CA/A"]).availability[0].state == .unavailable)
    }
    for fixture in [pickupJSON(display: "available", search: false), pickupJSON(selection: false), pickupJSON(eligible: false)] {
        #expect(try InventoryParser.parse(fixture, variantIDs: ["TEST-CA/A"]).availability[0].state == .disabled)
    }
    #expect(throws: AppleServiceError.self) { try InventoryParser.parse(pickupJSON(display: "new-unknown"), variantIDs: ["TEST-CA/A"]) }
    #expect(throws: AppleServiceError.self) { try InventoryParser.parse(pickupJSON(), variantIDs: ["MISSING"]) }
    #expect(throws: AppleServiceError.self) { try InventoryParser.parse(pickupJSON(duplicate: true), variantIDs: ["TEST-CA/A"]) }
    #expect(throws: AppleServiceError.self) { try InventoryParser.parse(Data("<html>Blocked</html>".utf8), variantIDs: ["TEST-CA/A"]) }
    #expect(try InventoryParser.parse(Data("{\"body\":{\"stores\":[]}}".utf8), variantIDs: ["TEST-CA/A"]).stores.isEmpty)
}
@Test func inventoryClientRequestsRegionalSKUsAndClassifiesErrors() async throws {
    let transport = InventoryTestTransport(HTTPResponse(data: pickupJSON(), statusCode: 200))
    let client = AppleInventoryClient(transport: transport)
    #expect(try await client.fetch(market: .ca, location: " M5V 3L9 ", variants: [testVariant()]).availability.first?.state == .available)
    let request = try #require(await transport.requests.first)
    let url = try #require(request.url)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(url.path == "/ca/shop/retail/pickup-message")
    #expect(query.contains(URLQueryItem(name: "parts.0", value: "TEST-CA/A")))
    #expect(query.contains(URLQueryItem(name: "location", value: "M5V 3L9")))
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("PickupPilot") == true)
    await #expect(throws: AppleServiceError.self) { try await client.fetch(market: .ca, location: "", variants: [testVariant()]) }
    await #expect(throws: AppleServiceError.self) { try await client.fetch(market: .ca, location: "M5B", variants: []) }
    await #expect(throws: AppleServiceError.self) { try await client.fetch(market: .uk, location: "SW1", variants: [testVariant()]) }
    let blocked = AppleInventoryClient(transport: InventoryTestTransport(HTTPResponse(data: Data(), statusCode: 541)))
    await #expect(throws: AppleServiceError.blocked(541)) { try await blocked.fetch(market: .ca, location: "M5B", variants: [testVariant()]) }
}
@Test func httpClassifiesAuthenticationBlockingThrottleAndServerFailures() throws {
    for code in [200, 204, 299] { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: code)) }
    #expect(throws: AppleServiceError.authenticationRequired) { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 401)) }
    for code in [403, 541] { #expect(throws: AppleServiceError.blocked(code)) { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: code)) } }
    #expect(throws: AppleServiceError.rateLimited(retryAfter: 120)) { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": "120"])) }
    #expect(throws: AppleServiceError.rateLimited(retryAfter: nil)) { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 429)) }
    #expect(throws: AppleServiceError.httpStatus(503)) { try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 503)) }
    #expect(AppleServiceError.rateLimited(retryAfter: nil).retryDelay == 60)
    #expect(AppleServiceError.rateLimited(retryAfter: 120).retryDelay == 120)
    #expect(AppleServiceError.blocked(541).retryDelay == 300)
    #expect(AppleServiceError.httpStatus(503).retryDelay == 60)
    #expect(AppleServiceError.httpStatus(400).retryDelay == nil)
    let errors: [AppleServiceError] = [.invalidInput("x"), .authenticationRequired, .blocked(541), .rateLimited(retryAfter: nil),
        .httpStatus(500), .invalidResponse("x"), .unsupportedMarket("ZZ"), .productUnavailable(.ca)]
    for error in errors { #expect(error.errorDescription?.isEmpty == false) }
}
@Test func retryAfterDatesAndInvalidHintsRetainServerBackoff() throws {
    let now = Date(timeIntervalSince1970: 1_792_166_400)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    let date = formatter.string(from: now.addingTimeInterval(600))
    #expect(throws: AppleServiceError.rateLimited(retryAfter: 600)) {
        try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": date]), now: now)
    }
    for value in ["-1", "nan", "inf", "invalid"] {
        #expect(throws: AppleServiceError.rateLimited(retryAfter: nil)) {
            try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": value]), now: now)
        }
    }
    let past = formatter.string(from: now.addingTimeInterval(-600))
    #expect(throws: AppleServiceError.rateLimited(retryAfter: 0)) {
        try AppleHTTP.validate(HTTPResponse(data: Data(), statusCode: 429, headers: ["Retry-After": past]), now: now)
    }
    #expect(AppleServiceError.rateLimited(retryAfter: 0).retryDelay == 60)
}
@Test func catalogExtractsAuthoritativeRegionalSKUsCurrencyAndSelectedLinks() throws {
    for (market, sku, currency) in [(Market.ca, "MK254VC/A", "CAD"), (.uk, "MK2E4QN/A", "GBP"), (.us, "LOCAL-US/A", "USD")] {
        let products = try ProductCatalogParser.parse(catalogHTML(market: market, sku: sku, currency: currency), market: market)
        #expect(products == [testVariant(sku, market: market)])
        #expect(try JSONDecoder().decode(ProductVariant.self, from: JSONEncoder().encode(products[0])) == products[0])
    }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(catalogHTML(currency: "USD"), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(catalogHTML(family: "other"), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(catalogHTML(color: "unknown"), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(catalogHTML(link: "https://evil.example/ca/shop/buy-iphone/iphone-duo/7.6-inch-display-256gb-night-sky"), market: .ca) }
    #expect(throws: AppleServiceError.productUnavailable(.ca)) { try ProductCatalogParser.parse(Data("Not available here".utf8), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(Data([0xff]), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(Data("productSelectionData: {\"products\":".utf8), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(Data("productSelectionData: {}".utf8), market: .ca) }
    #expect(ProductCatalogParser.jsonObjectPrefix(" {} trailing".dropFirst()) == "{}")
    #expect(ProductCatalogParser.jsonObjectPrefix("{\"escaped\":\"}\\\"\\\\\",\"object\":{}}"[...]) != nil)
    #expect(ProductCatalogParser.jsonObjectPrefix("[]"[...]) == nil)
}
@Test func catalogClientUsesSelectedStorefrontAndReportsUnavailable() async throws {
    let transport = InventoryTestTransport(HTTPResponse(data: catalogHTML(), statusCode: 200))
    #expect(try await ProductCatalogClient(transport: transport).variants(market: .ca).count == 1)
    #expect(await transport.requests.first?.url == Market.ca.productBaseURL)
    let explicitPhone = InventoryTestTransport(HTTPResponse(data: catalogHTML(), statusCode: 200))
    #expect(try await ProductCatalogClient(transport: explicitPhone).variants(market: .ca, product: .iPhoneDuo).count == 1)
    let phoneRequests = await explicitPhone.requests
    #expect(phoneRequests.count == 1 && phoneRequests.first?.url == Market.ca.productBaseURL)
    await #expect(throws: AppleServiceError.productUnavailable(.uk)) {
        try await ProductCatalogClient(transport: InventoryTestTransport(HTTPResponse(data: Data(), statusCode: 404))).variants(market: .uk)
    }
    await #expect(throws: AppleServiceError.authenticationRequired) {
        try await ProductCatalogClient(transport: InventoryTestTransport(HTTPResponse(data: Data(), statusCode: 401))).variants(market: .ca)
    }
}

// URLProtocol owns per-request state. This fixture has no shared mutable state; routes are immutable request paths.
private final class InventoryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/network-error" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response: URLResponse = url.path == "/non-http" ? URLResponse(url: url, mimeType: "application/json", expectedContentLength: 2, textEncodingName: nil) :
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["X-Fixture": "synthetic"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func nativeTransportPreservesHTTPAndNetworkFailuresWithoutStoringCookies() async throws {
    _ = URLSessionTransport()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InventoryFixtureURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = URLSessionTransport(session: session)
    let response = try await transport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/success")!))
    #expect(response.statusCode == 200)
    #expect(response.data == Data("{}".utf8))
    #expect(response.headers["x-fixture"] == "synthetic")
    await #expect(throws: AppleServiceError.invalidResponse("Expected HTTP response")) {
        try await transport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/non-http")!))
    }
    await #expect(throws: URLError.self) {
        try await transport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/network-error")!))
    }
}
@Test func catalogSelectsUnconnectedCarrierPolicyWithoutGuessingRegionalIdentifiers() throws {
    let data = Data("""
    <a href="https://www.apple.com/shop/buy-iphone/iphone-duo/7.6-inch-display-256gb-night-sky-unlocked">Unlocked</a>
    productSelectionData: {"products":[
      {"partNumber":"REGIONAL-US/A","familyType":"iphoneduo","dimensionCapacity":"256gb","dimensionColor":"nightsky","isCarrierDevice":true,"seoUrlToken":"7.6-inch-display-256gb-night-sky-att"},
      {"partNumber":"REGIONAL-US/A","familyType":"iphoneduo","dimensionCapacity":"256gb","dimensionColor":"nightsky","isCarrierDevice":false,"seoUrlToken":"7.6-inch-display-256gb-night-sky-unlocked","fullPrice":"unconnected"}],
      "displayValues":{"dimensionColor":{"nightsky":{"value":"Night Sky"}},"prices":{"unconnected":{"partNumber":"REGIONAL-US/A","priceCurrency":"USD"}}}}
    """.utf8)
    let variants = try ProductCatalogParser.parse(data, market: .us)
    #expect(variants.count == 1)
    #expect(variants[0].id == "REGIONAL-US/A")
    #expect(variants[0].productURL.lastPathComponent.hasSuffix("-unlocked"))
}
@Test func inventoryRejectsMissingFieldsDuplicateSelectionsAndForeignHosts() async throws {
    for text in [
        "{\"body\":{\"stores\":[{\"storeNumber\":\"\",\"storeName\":\"Empty\",\"partsAvailability\":{}}]}}",
        "{\"body\":{\"stores\":[{\"storeNumber\":\"R1\",\"storeName\":\"Store\",\"partsAvailability\":{\"A\":{\"pickupDisplay\":\"available\"}}}]}}"
    ] { #expect(throws: AppleServiceError.self) { try InventoryParser.parse(Data(text.utf8), variantIDs: ["A"]) } }
    let client = AppleInventoryClient(transport: InventoryTestTransport(HTTPResponse(data: pickupJSON(), statusCode: 200)))
    await #expect(throws: AppleServiceError.self) { try await client.fetch(market: .ca, location: "M5B", variants: [testVariant(), testVariant()]) }
    var foreign = testVariant()
    foreign.productURL = URL(string: "https://example.com/ca/shop/buy-iphone/iphone-duo/synthetic")!
    await #expect(throws: AppleServiceError.self) { try await client.fetch(market: .ca, location: "M5B", variants: [foreign]) }
    let cancellationTransport = InventoryCancellationTransport(response: HTTPResponse(data: pickupJSON(), statusCode: 200))
    let cancellationClient = AppleInventoryClient(transport: cancellationTransport)
    let cancelled = Task { try await cancellationClient.fetch(market: .ca, location: "M5B", variants: [testVariant()]) }
    await cancellationTransport.waitForEntry()
    cancelled.cancel()
    await cancellationTransport.release()
    do { _ = try await cancelled.value; Issue.record("Cancelled fetch unexpectedly completed") }
    catch { #expect(error is CancellationError) }
}

@Test func inventoryQuoteFallbacksKeepUnavailableDetailsHonest() throws {
    let source = String(decoding: pickupJSON(), as: UTF8.self)
    let searchOnly = source.replacingOccurrences(of: ",\"storePickupQuote\":\"Today\"", with: "")
    #expect(try InventoryParser.parse(Data(searchOnly.utf8), variantIDs: ["TEST-CA/A"]).availability[0].message == "Pickup quote")
    let noQuote = searchOnly.replacingOccurrences(of: ",\"pickupSearchQuote\":\"Pickup quote\"", with: "")
    #expect(try InventoryParser.parse(Data(noQuote.utf8), variantIDs: ["TEST-CA/A"]).availability[0].message == "No pickup quote supplied")
}
@Test func regionalCatalogSortsAllConfigurationsAndRejectsEmptyOrCarrierOnlyCatalogs() throws {
    let combinations = [("2tb", "nightsky", "Night Sky"), ("256gb", "starwhite", "Star White"),
                        ("512gb", "nightsky", "Night Sky"), ("256gb", "nightsky", "Night Sky"), ("4tb", "nightsky", "Night Sky")]
    var products: [[String: Any]] = []
    var links = ""
    for (index, combination) in combinations.enumerated() {
        let (capacity, color, _) = combination
        products.append(["partNumber": "REGIONAL-\(index)/A", "familyType": "iphoneduo", "dimensionCapacity": capacity, "dimensionColor": color])
        let slug = color == "nightsky" ? "night-sky" : "star-white"
        links += "<a href=\"https://www.apple.com/ca/shop/buy-iphone/iphone-duo/7.6-inch-display-\(capacity)-\(slug)\">Select</a>"
    }
    let display: [String: Any] = ["dimensionColor": ["nightsky": ["value": "Night Sky"], "starwhite": ["value": "Star White"]],
        "prices": ["shared": ["partNumber": "BASE/A", "priceCurrency": "CAD", "validProducts": products.map { $0["partNumber"] as! String }]]]
    func page(_ products: [[String: Any]]) throws -> Data {
        let selection = try JSONSerialization.data(withJSONObject: ["products": products, "displayValues": display], options: [.sortedKeys])
        return Data((links + "productSelectionData: " + String(decoding: selection, as: UTF8.self)).utf8)
    }
    let variants = try ProductCatalogParser.parse(page(products), market: .ca)
    #expect(variants.map(\.id) == ["REGIONAL-3/A", "REGIONAL-1/A", "REGIONAL-2/A", "REGIONAL-0/A", "REGIONAL-4/A"])
    #expect(try ProductCatalogParser.parse(page(Array(products.reversed())), market: .ca) == variants)
    #expect(throws: AppleServiceError.productUnavailable(.ca)) { try ProductCatalogParser.parse(page([]), market: .ca) }
    let carrierOnly = products.map { $0.merging(["isCarrierDevice": true]) { _, new in new } }
    #expect(throws: AppleServiceError.productUnavailable(.ca)) { try ProductCatalogParser.parse(page(carrierOnly), market: .ca) }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parse(page([products[0], products[0]]), market: .ca) }
}

@Test func liveInventoryRequiresStoresInSelectedCountry() throws {
    #expect(try InventoryParser.parse(pickupJSON(), variantIDs: ["TEST-CA/A"], market: .ca).stores.first?.countryCode == "CA")
    #expect(throws: AppleServiceError.self) { try InventoryParser.parse(pickupJSON(), variantIDs: ["TEST-CA/A"], market: .uk) }
}

private actor InventoryCancellationTransport: HTTPTransport {
    let response: HTTPResponse
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    init(response: HTTPResponse) { self.response = response }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { completion = $0 }
        return response
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { completion?.resume(); completion = nil }
}
@Test func cancelledCatalogRequestCannotPublishLateRegionalProducts() async {
    let transport = InventoryCancellationTransport(response: HTTPResponse(data: catalogHTML(), statusCode: 200))
    let client = ProductCatalogClient(transport: transport)
    let request = Task { try await client.variants(market: .ca) }
    await transport.waitForEntry(); request.cancel(); await transport.release()
    do { _ = try await request.value; Issue.record("Cancelled catalog unexpectedly completed") }
    catch { #expect(error is CancellationError) }
}

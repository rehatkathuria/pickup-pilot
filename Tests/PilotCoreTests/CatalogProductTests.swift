import Foundation
import Testing
@testable import PilotCore

private actor CatalogProductTransport: HTTPTransport {
    let response: HTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: HTTPResponse) { self.response = response }
    func data(for request: URLRequest) -> HTTPResponse { requests.append(request); return response }
}

private actor PhoneOnlyCatalog: ProductCatalogFetching {
    private(set) var calls = 0
    func variants(market: Market) -> [ProductVariant] { calls += 1; return [] }
}

private func adapterFixture(sku: String = CatalogProduct.adapterSKU, currency: String = "CAD", price: Any = 10.0,
                            url: String = CatalogProduct.adapterURL.absoluteString,
                            canonical: String? = CatalogProduct.adapterURL.absoluteString,
                            mainEntity: String = CatalogProduct.adapterURL.absoluteString, offerCount: Int = 1,
                            productSKU: String? = nil) throws -> Data {
    let offer: [String: Any] = ["@type": "Offer", "priceCurrency": currency, "price": price, "sku": sku]
    var product: [String: Any] = ["@context": "https://schema.org", "@type": "Product", "name": "USB-C to 3.5mm Headphone Jack Adapter",
                                "url": url, "mainEntityOfPage": mainEntity, "offers": Array(repeating: offer, count: offerCount)]
    if let productSKU { product["sku"] = productSKU }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: product), as: UTF8.self)
    let link = canonical.map { "<link rel='canonical' href='\($0)'>" } ?? ""
    return Data("<html><head>\(link)<script type='application/ld+json'>\(json)</script></head></html>".utf8)
}

@Test func explicitCatalogPolicyRestrictsTheAdapterToItsExactCanadianIdentity() {
    let adapter = ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic adapter", storage: "", color: "", productURL: CatalogProduct.adapterURL)
    let phone = ProductVariant(id: "TEST-CA/A", name: "Synthetic phone", storage: "256GB", color: "Synthetic", productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic"))
    #expect(CatalogProduct.usbCHeadphoneAdapter.permits(variant: adapter, market: .ca))
    #expect(CatalogProduct.iPhoneDuo.permits(variant: phone, market: .ca))
    #expect(!CatalogProduct.iPhoneDuo.permits(variant: adapter, market: .ca))
    #expect(!CatalogProduct.usbCHeadphoneAdapter.permits(variant: phone, market: .ca))
    for market in Market.allCases {
        #expect(CatalogProduct.iPhoneDuo.supports(market: market))
        #expect(CatalogProduct.iPhoneDuo.productURL(in: market) == market.productBaseURL)
        #expect(CatalogProduct.usbCHeadphoneAdapter.supports(market: market) == (market == .ca))
        #expect(CatalogProduct.usbCHeadphoneAdapter.permits(variant: adapter, market: market) == (market == .ca))
        if market != .ca { #expect(CatalogProduct.usbCHeadphoneAdapter.productURL(in: market) == nil) }
    }
    for address in [CatalogProduct.adapterURL.absoluteString + "?other=1", CatalogProduct.adapterURL.absoluteString + "#other",
                    "http://www.apple.com/ca/shop/product/mw2q3am/a/usb-c-to-35mm-headphone-jack-adapter",
                    "https://apple.com.evil.test/ca/shop/product/mw2q3am/a/usb-c-to-35mm-headphone-jack-adapter",
                    "https://user@www.apple.com/ca/shop/product/mw2q3am/a/usb-c-to-35mm-headphone-jack-adapter",
                    "https://www.apple.com/uk/shop/product/mw2q3am/a/usb-c-to-35mm-headphone-jack-adapter"] {
        var changed = adapter; changed.productURL = URL(string: address)!
        #expect(!CatalogProduct.usbCHeadphoneAdapter.permits(variant: changed, market: .ca))
    }
    var changed = adapter; changed.id = "OTHER-CA/A"
    #expect(!CatalogProduct.usbCHeadphoneAdapter.permits(variant: changed, market: .ca))
    changed = phone; changed.id = CatalogProduct.adapterSKU
    #expect(!CatalogProduct.iPhoneDuo.permits(variant: changed, market: .ca))
    #expect(CatalogProduct.allCases.count == 2 && CatalogProduct.allCases.allSatisfy { !$0.displayName.isEmpty })
}

@Test func adapterCatalogUsesCurrentStructuredOfferWithoutAssumingItsPrice() throws {
    let variants = try ProductCatalogParser.parseAdapter(adapterFixture(), market: .ca)
    #expect(variants.count == 1 && variants[0].id == CatalogProduct.adapterSKU && variants[0].productURL == CatalogProduct.adapterURL)
    #expect(variants[0].name.contains("Adapter") && variants[0].name.contains("10"))
    let changedPrice = try ProductCatalogParser.parseAdapter(adapterFixture(price: 12.5), market: .ca)
    #expect(changedPrice[0].name != variants[0].name)
    let invalid = try [adapterFixture(sku: "OTHER/A"), adapterFixture(currency: "USD"), adapterFixture(price: 0),
                       adapterFixture(price: -1), adapterFixture(price: "NaN"), adapterFixture(price: true),
                       adapterFixture(url: "https://www.apple.com/ca/shop/product/other"), adapterFixture(canonical: nil),
                       adapterFixture(canonical: "https://www.apple.com/uk/shop/product/other"),
                       adapterFixture(mainEntity: "https://example.invalid/other"), adapterFixture(offerCount: 0),
                       adapterFixture(offerCount: 2), adapterFixture(productSKU: "OTHER/A")]
    for data in invalid { #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parseAdapter(data, market: .ca) } }
    for data in [Data([0xff]), Data("<html>Unknown page</html>".utf8)] {
        #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parseAdapter(data, market: .ca) }
    }
    #expect(throws: AppleServiceError.self) { try ProductCatalogParser.parseAdapter(adapterFixture(), market: .uk) }
}

@Test func selectedCatalogMakesOneRequestAndPhoneOnlyMocksNeverReturnAnAccessory() async throws {
    let transport = CatalogProductTransport(HTTPResponse(data: try adapterFixture(), statusCode: 200))
    let client = ProductCatalogClient(transport: transport)
    #expect(try await client.variants(market: .ca, product: .usbCHeadphoneAdapter).first?.id == CatalogProduct.adapterSKU)
    #expect(await transport.requests.map(\.url) == [CatalogProduct.adapterURL])
    await #expect(throws: AppleServiceError.self) { try await client.variants(market: .uk, product: .usbCHeadphoneAdapter) }
    #expect(await transport.requests.count == 1)
    let mock = PhoneOnlyCatalog()
    #expect(try await mock.variants(market: .ca, product: .iPhoneDuo).isEmpty)
    await #expect(throws: AppleServiceError.self) { try await mock.variants(market: .ca, product: .usbCHeadphoneAdapter) }
    #expect(await mock.calls == 1)
    let unavailable = ProductCatalogClient(transport: CatalogProductTransport(HTTPResponse(data: Data(), statusCode: 404)))
    await #expect(throws: AppleServiceError.self) { try await unavailable.variants(market: .ca, product: .usbCHeadphoneAdapter) }
}

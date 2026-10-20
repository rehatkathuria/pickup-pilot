import Foundation

public protocol ProductCatalogFetching: Sendable {
    func variants(market: Market) async throws -> [ProductVariant]
    func variants(market: Market, product: CatalogProduct) async throws -> [ProductVariant]
}
public extension ProductCatalogFetching {
    func variants(market: Market, product: CatalogProduct) async throws -> [ProductVariant] {
        guard product == .iPhoneDuo else { throw AppleServiceError.invalidInput("This catalog does not provide the selected accessory.") }
        return try await variants(market: market)
    }
}
public actor ProductCatalogClient: ProductCatalogFetching {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func variants(market: Market) async throws -> [ProductVariant] {
        try await variants(market: market, product: .iPhoneDuo)
    }
    public func variants(market: Market, product: CatalogProduct) async throws -> [ProductVariant] {
        try Task.checkCancellation()
        guard let url = product.productURL(in: market) else { throw AppleServiceError.invalidInput("The headphone adapter option is available only for Canada.") }
        let response = try await transport.data(for: AppleHTTP.request(url: url))
        try Task.checkCancellation()
        if response.statusCode == 404 {
            if product == .iPhoneDuo { throw AppleServiceError.productUnavailable(market) }
            throw AppleServiceError.invalidResponse("The selected headphone adapter product page is unavailable.")
        }
        try AppleHTTP.validate(response)
        switch product {
        case .iPhoneDuo: return try ProductCatalogParser.parse(response.data, market: market)
        case .usbCHeadphoneAdapter: return try ProductCatalogParser.parseAdapter(response.data, market: market)
        }
    }
}
public enum ProductCatalogParser {
    /// The adapter uses the Product JSON-LD and canonical link verified on the official Canadian page.
    public static func parseAdapter(_ data: Data, market: Market) throws -> [ProductVariant] {
        guard market == .ca else { throw AppleServiceError.invalidInput("The headphone adapter option is available only for Canada.") }
        guard let html = String(data: data, encoding: .utf8) else { throw AppleServiceError.invalidResponse("Product page is not UTF-8") }
        let canonicalTags = matches(#"(?is)<link\b[^>]*>"#, in: html).filter { attribute("rel", in: $0)?.lowercased() == "canonical" }
        guard canonicalTags.count == 1, attribute("href", in: canonicalTags[0]) == CatalogProduct.adapterURL.absoluteString else {
            throw AppleServiceError.invalidResponse("The accessory's Canadian canonical URL could not be verified")
        }
        let scripts = matches(#"(?is)<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#, in: html, group: 1)
        let products = scripts.compactMap { script -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(script.utf8)) as? [String: Any],
                  object["@type"] as? String == "Product" else { return nil }
            return object
        }
        guard products.count == 1, let encoded = try? JSONSerialization.data(withJSONObject: products[0]),
              let product = try? JSONDecoder().decode(AccessoryProduct.self, from: encoded),
              product.url == CatalogProduct.adapterURL.absoluteString,
              product.sku == nil || product.sku == CatalogProduct.adapterSKU,
              product.mainEntityOfPage == nil || product.mainEntityOfPage == CatalogProduct.adapterURL.absoluteString,
              !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              product.offers.count == 1, let offer = product.offers.first,
              offer.type == "Offer", offer.sku == CatalogProduct.adapterSKU, offer.priceCurrency == market.currencyCode,
              !offer.price.isNaN, offer.price > 0 else {
            throw AppleServiceError.invalidResponse("The accessory SKU, currency, price or product identity could not be verified")
        }
        let variant = ProductVariant(id: offer.sku, name: "\(product.name) · \(offer.price.formatted(.currency(code: market.currencyCode)))",
                                     storage: "", color: "", productURL: CatalogProduct.adapterURL)
        guard CatalogProduct.usbCHeadphoneAdapter.permits(variant: variant, market: market) else {
            throw AppleServiceError.invalidResponse("The selected accessory is outside the supported catalog")
        }
        return [variant]
    }

    private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: group)) }
    }
    private static func attribute(_ name: String, in tag: String) -> String? {
        matches("(?is)\\b" + name + #"\s*=\s*["']([^"']*)["']"#, in: tag, group: 1).first
    }
    private struct AccessoryProduct: Decodable {
        let name: String
        let url: String
        let sku: String?
        let mainEntityOfPage: String?
        let offers: [AccessoryOffer]
    }
    private struct AccessoryOffer: Decodable {
        let type: String
        let sku: String
        let priceCurrency: String
        let price: Decimal
        private enum CodingKeys: String, CodingKey { case type = "@type", sku, priceCurrency, price }
    }

    public static func parse(_ data: Data, market: Market) throws -> [ProductVariant] {
        guard let html = String(data: data, encoding: .utf8) else { throw AppleServiceError.invalidResponse("Product page is not UTF-8") }
        guard let marker = html.range(of: "productSelectionData:") else { throw AppleServiceError.productUnavailable(market) }
        let remaining = html[marker.upperBound...].drop(while: \.isWhitespace)
        guard let json = jsonObjectPrefix(remaining) else { throw AppleServiceError.invalidResponse("Product selection JSON is truncated") }
        let selection: Selection
        do { selection = try JSONDecoder().decode(Selection.self, from: Data(json.utf8)) }
        catch { throw AppleServiceError.invalidResponse("Product selection schema changed") }
        guard !selection.products.isEmpty else { throw AppleServiceError.productUnavailable(market) }
        let links = productLinks(in: html, market: market)
        var seen = Set<String>()
        // Carrier contracts require additional account inputs. Offer authoritative unconnected SKUs only.
        let products = selection.products.filter { $0.isCarrierDevice != true }
        guard !products.isEmpty else { throw AppleServiceError.productUnavailable(market) }
        let variants = try products.map { product -> ProductVariant in
            guard product.familyType == "iphoneduo", !product.partNumber.isEmpty,
                  seen.insert(product.partNumber).inserted,
                  let color = selection.displayValues.dimensionColor[product.dimensionColor]?.value,
                  let url = links.first(where: {
                      if let seo = product.seoUrlToken, !seo.isEmpty { return $0.lastPathComponent == seo }
                      let token = $0.lastPathComponent.replacingOccurrences(of: "-", with: "").lowercased()
                      return token.contains(product.dimensionCapacity.lowercased()) && token.hasSuffix(product.dimensionColor.lowercased())
                  }) else { throw AppleServiceError.invalidResponse("A regional SKU, dimension, or selected-product URL is missing") }
            let price = product.fullPrice.flatMap { selection.displayValues.prices[$0] } ??
                selection.displayValues.prices.values.first { $0.partNumber == product.partNumber || $0.validProducts?.contains(product.partNumber) == true }
            guard let price, price.priceCurrency == market.currencyCode else {
                throw AppleServiceError.invalidResponse("Regional product currency could not be verified")
            }
            let storage = product.dimensionCapacity.uppercased()
            return ProductVariant(id: product.partNumber, name: "iPhone Duo \(storage) \(color)", storage: storage, color: color, productURL: url)
        }
        return variants.sorted {
            if $0.storage == $1.storage { return $0.color < $1.color }
            let capacities = ["256GB": 256, "512GB": 512, "1TB": 1024, "2TB": 2048]
            return (capacities[$0.storage] ?? Int.max, $0.storage) < (capacities[$1.storage] ?? Int.max, $1.storage)
        }
    }
    /// Extract a JSON object without evaluating JavaScript or accepting trailing executable content.
    static func jsonObjectPrefix(_ text: Substring) -> Substring? {
        guard text.first == "{" else { return nil }
        var depth = 0; var inString = false; var escaped = false
        for index in text.indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" { inString = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return text[...index] }
            }
        }
        return nil
    }
    private static func productLinks(in html: String, market: Market) -> [URL] {
        let expression = try! NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+/shop/buy-iphone/iphone-duo/[^"'?]+)["']"#)
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html), let url = URL(string: String(html[range]), relativeTo: market.productBaseURL)?.absoluteURL,
                  url.scheme == "https", url.host == "www.apple.com", url.path.hasPrefix(market.productBaseURL.path + "/") else { return nil }
            return url
        }
    }
    private struct Selection: Decodable { let products: [Product]; let displayValues: DisplayValues }
    private struct Product: Decodable {
        let partNumber: String; let familyType: String; let dimensionColor: String; let dimensionCapacity: String
        let isCarrierDevice: Bool?; let seoUrlToken: String?; let fullPrice: String?
    }
    private struct DisplayValues: Decodable { let dimensionColor: [String: DisplayValue]; let prices: [String: Price] }
    private struct DisplayValue: Decodable {
        let value: String?
        private enum CodingKeys: String, CodingKey { case value }
        init(from decoder: any Decoder) throws {
            value = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
        }
    }
    private struct Price: Decodable { let partNumber: String; let priceCurrency: String; let validProducts: [String]? }
}

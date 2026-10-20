import Foundation

/// Explicit supported catalogs. The accessory option is restricted to its verified Canadian SKU and URL.
public enum CatalogProduct: String, Codable, CaseIterable, Identifiable, Sendable {
    case iPhoneDuo, usbCHeadphoneAdapter
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .iPhoneDuo: "iPhone Duo"
        case .usbCHeadphoneAdapter: "USB-C to 3.5 mm Headphone Jack Adapter"
        }
    }
    public static let adapterSKU = "MW2Q3AM/A"
    public static let adapterURL = URL(string: "https://www.apple.com/ca/shop/product/mw2q3am/a/usb-c-to-35mm-headphone-jack-adapter")!
    public func supports(market: Market) -> Bool { self == .iPhoneDuo || market == .ca }
    public func productURL(in market: Market) -> URL? {
        guard supports(market: market) else { return nil }
        return self == .iPhoneDuo ? market.productBaseURL : Self.adapterURL
    }
    public func permits(variant: ProductVariant, market: Market) -> Bool {
        guard supports(market: market), CheckoutPagePolicy.isStorefront(variant.productURL, market: market),
              variant.productURL.host == "www.apple.com" else { return false }
        switch self {
        case .iPhoneDuo:
            return variant.id != Self.adapterSKU && variant.productURL.path.hasPrefix(market.productBaseURL.path + "/")
        case .usbCHeadphoneAdapter:
            return variant.id == Self.adapterSKU && variant.productURL.absoluteString == Self.adapterURL.absoluteString
        }
    }
}

public struct ProductVariant: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var storage: String
    public var color: String
    public var productURL: URL
    public init(id: String, name: String, storage: String, color: String, productURL: URL) {
        self.id = id; self.name = name; self.storage = storage; self.color = color; self.productURL = productURL
    }
}

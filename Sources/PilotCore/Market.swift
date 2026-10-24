import Foundation

/// Candidate Apple online storefronts. Product and pickup support are verified from each live storefront.
public enum Market: String, Codable, CaseIterable, Identifiable, Sendable {
    case ca, us, uk, au, de, fr, it, es, jp, cn, hk, sg, ae, `in`, mx, kr, tw, th, my, nl, se, ch, at, be
    public var id: String { rawValue }
    public var storefrontPath: String { self == .us ? "" : "/\(rawValue)" }
    public var currencyCode: String {
        switch self {
        case .ca: "CAD"; case .us: "USD"; case .uk: "GBP"; case .au: "AUD"
        case .de, .fr, .it, .es, .nl, .at, .be: "EUR"
        case .jp: "JPY"; case .cn: "CNY"; case .hk: "HKD"; case .sg: "SGD"
        case .ae: "AED"; case .in: "INR"; case .mx: "MXN"; case .kr: "KRW"
        case .tw: "TWD"; case .th: "THB"; case .my: "MYR"; case .se: "SEK"; case .ch: "CHF"
        }
    }
    public var countryCode: String { self == .uk ? "GB" : rawValue.uppercased() }
    public var displayName: String {
        switch self {
        case .ca: "Canada"; case .us: "United States"; case .uk: "United Kingdom"; case .au: "Australia"
        case .de: "Germany"; case .fr: "France"; case .it: "Italy"; case .es: "Spain"; case .jp: "Japan"
        case .cn: "China mainland"; case .hk: "Hong Kong"; case .sg: "Singapore"; case .ae: "United Arab Emirates"
        case .in: "India"; case .mx: "Mexico"; case .kr: "South Korea"; case .tw: "Taiwan"; case .th: "Thailand"
        case .my: "Malaysia"; case .nl: "Netherlands"; case .se: "Sweden"; case .ch: "Switzerland"
        case .at: "Austria"; case .be: "Belgium"
        }
    }
    public init?(countryCode: String) {
        let code = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.init(rawValue: code == "gb" ? "uk" : code)
    }
    public var productBaseURL: URL { URL(string: "https://www.apple.com\(storefrontPath)/shop/buy-iphone/iphone-duo")! }
}

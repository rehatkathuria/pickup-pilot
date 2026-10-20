import Foundation

/// Sensitive checkout input. This deliberately does not conform to Codable:
/// only the vault's private record format may serialize these values.
/// Swift strings can create transient copies and cannot promise secure zeroization.
public struct SecureProfile: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var givenName: String
    public var familyName: String
    public var email: String
    public var phone: String
    public var cardholder: String
    public var cardNumber: String
    public var expiryMonth: String
    public var expiryYear: String
    public var cvv: String
    public var billingLine1: String
    public var billingLine2: String
    public var billingCity: String
    public var billingRegion: String
    public var billingPostalCode: String
    public var billingCountry: String
    public var searchLocation: String

    public init(
        givenName: String = "", familyName: String = "", email: String = "", phone: String = "",
        cardholder: String = "", cardNumber: String = "", expiryMonth: String = "", expiryYear: String = "",
        cvv: String = "", billingLine1: String = "", billingLine2: String = "", billingCity: String = "",
        billingRegion: String = "", billingPostalCode: String = "", billingCountry: String = "",
        searchLocation: String = ""
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.email = email
        self.phone = phone
        self.cardholder = cardholder
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.billingLine1 = billingLine1
        self.billingLine2 = billingLine2
        self.billingCity = billingCity
        self.billingRegion = billingRegion
        self.billingPostalCode = billingPostalCode
        self.billingCountry = billingCountry
        self.searchLocation = searchLocation
    }

    public var description: String { "<SecureProfile redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": "Sensitive checkout details"]) }

    public var isEmpty: Bool { fields.values.allSatisfy { $0.isEmpty } }
    public var validationIssues: [String] { validationIssues(at: Date()) }

    /// Local input checks only; Apple/payment-provider acceptance is still required.
    public func validationIssues(at date: Date) -> [String] {
        var issues: [String] = []
        let required: [(String, String)] = [
            (givenName, "Given name"), (familyName, "Family name"), (cardholder, "Cardholder"),
            (billingLine1, "Billing street"), (billingCity, "Billing city")
        ]
        for (value, label) in required where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(label) is required.")
        }
        let emailParts = email.split(separator: "@", omittingEmptySubsequences: false)
        if emailParts.count != 2 || emailParts[0].isEmpty || !emailParts[1].contains(".")
            || email.contains(where: { $0.isWhitespace }) {
            issues.append("Enter a valid email address.")
        }
        let phoneDigits = phone.filter { $0.isASCIIDigit }
        if !(7...15).contains(phoneDigits.count)
            || phone.contains(where: { !$0.isASCIIDigit && !"+()- ".contains($0) }) {
            issues.append("Enter a valid phone number.")
        }
        let number = cardNumber.filter { $0 != " " && $0 != "-" }
        if !Self.isValidCardNumber(number) { issues.append("Enter a valid card number.") }
        if !(3...4).contains(cvv.count) || !cvv.allSatisfy(\.isASCIIDigit) {
            issues.append("Enter a three or four digit security code.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentYear = calendar.component(.year, from: date)
        let currentMonth = calendar.component(.month, from: date)
        if !expiryMonth.allSatisfy(\.isASCIIDigit) || !expiryYear.allSatisfy(\.isASCIIDigit)
            || !(1...2).contains(expiryMonth.count) || expiryYear.count != 4 {
            issues.append("Enter an expiry month and four digit year.")
        } else if let month = Int(expiryMonth), let year = Int(expiryYear), (1...12).contains(month),
                  year > currentYear || (year == currentYear && month >= currentMonth) {
            // Cards remain valid through the end of their expiry month.
        } else {
            issues.append("The card expiry date is invalid or expired.")
        }
        let country = billingCountry.uppercased()
        if country.count != 2 || !country.allSatisfy({ $0.isASCII && $0.isLetter }) {
            issues.append("Choose a two letter billing country code.")
        }
        if ["CA", "US", "AU"].contains(country), billingRegion.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Billing province or state is required.")
        }
        // These supported markets do not require postal codes. Apple validates the full address.
        if !["HK", "AE", "MO", "QA"].contains(country), billingPostalCode.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Billing postal code is required.")
        }
        return issues
    }

    private static func isValidCardNumber(_ number: String) -> Bool {
        guard (13...19).contains(number.count), number.allSatisfy(\.isASCIIDigit),
              number.contains(where: { $0 != "0" }) else { return false }
        let sum = number.reversed().enumerated().reduce(0) { result, entry in
            let digit = Int(String(entry.element))!
            let doubled = entry.offset.isMultiple(of: 2) ? digit : digit * 2
            return result + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10)
    }

    // Shared only with the vault codec, never ordinary preferences or app reports.
    var fields: [String: String] {
        ["givenName": givenName, "familyName": familyName, "email": email, "phone": phone,
         "cardholder": cardholder, "cardNumber": cardNumber, "expiryMonth": expiryMonth,
         "expiryYear": expiryYear, "cvv": cvv, "billingLine1": billingLine1, "billingLine2": billingLine2,
         "billingCity": billingCity, "billingRegion": billingRegion, "billingPostalCode": billingPostalCode,
         "billingCountry": billingCountry, "searchLocation": searchLocation]
    }

    init(fields: [String: String]) throws {
        guard Set(fields.keys) == Set(SecureProfile().fields.keys) else { throw SecureVaultError.malformedProfile }
        self.init(
            givenName: fields["givenName"]!, familyName: fields["familyName"]!, email: fields["email"]!,
            phone: fields["phone"]!, cardholder: fields["cardholder"]!, cardNumber: fields["cardNumber"]!,
            expiryMonth: fields["expiryMonth"]!, expiryYear: fields["expiryYear"]!, cvv: fields["cvv"]!,
            billingLine1: fields["billingLine1"]!, billingLine2: fields["billingLine2"]!,
            billingCity: fields["billingCity"]!, billingRegion: fields["billingRegion"]!,
            billingPostalCode: fields["billingPostalCode"]!, billingCountry: fields["billingCountry"]!,
            searchLocation: fields["searchLocation"]!
        )
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && ("0"..."9").contains(self) }
}

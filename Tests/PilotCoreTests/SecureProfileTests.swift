import Foundation
import Testing
@testable import PilotCore

private let validationDate = Date(timeIntervalSince1970: 1_792_137_600) // 2026-10-16 UTC

func syntheticSecureProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid",
                  phone: "+1 (416) 555-0100", cardholder: "Synthetic Tester", cardNumber: "4111111111111111",
                  expiryMonth: "12", expiryYear: "2035", cvv: "123", billingLine1: "1 Test Street",
                  billingLine2: "Unit 0", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9",
                  billingCountry: "CA", searchLocation: "Synthetic location")
}

@Test func secureProfileDefaultsRedactAndRoundTrip() throws {
    let empty = SecureProfile()
    #expect(empty.isEmpty)
    #expect(!empty.validationIssues.isEmpty)
    let profile = syntheticSecureProfile()
    #expect(!profile.isEmpty)
    #expect(profile.validationIssues(at: validationDate).isEmpty)
    #expect(profile.validationIssues.isEmpty)
    #expect(profile.description == "<SecureProfile redacted>")
    #expect(profile.debugDescription == "<SecureProfile redacted>")
    #expect(String(reflecting: profile) == "<SecureProfile redacted>")
    #expect(Mirror(reflecting: profile).children.map(\.label) == ["redacted"])
    #expect(Mirror(reflecting: profile).children.compactMap { $0.value as? String } == ["Sensitive checkout details"])
    #expect(try SecureProfile(fields: profile.fields) == profile)
    #expect(throws: SecureVaultError.malformedProfile) { try SecureProfile(fields: [:]) }
    var unknown = profile.fields
    unknown["unexpected"] = "synthetic"
    #expect(throws: SecureVaultError.malformedProfile) { try SecureProfile(fields: unknown) }
}

@Test func secureProfileRequiredFieldChecksNeverIncludeEnteredSecrets() {
    var profile = syntheticSecureProfile()
    profile.givenName = " \n"
    profile.familyName = ""
    profile.cardholder = ""
    profile.billingLine1 = ""
    profile.billingCity = ""
    profile.billingRegion = ""
    profile.billingPostalCode = ""
    let issues = profile.validationIssues(at: validationDate)
    #expect(issues.count == 7)
    #expect(!issues.joined().contains(profile.cardNumber))
    #expect(!issues.joined().contains(profile.cvv))
    profile.searchLocation = ""
    #expect(profile.validationIssues(at: validationDate) == issues)
}

@Test(arguments: ["", "a", "a@", "@example.invalid", "a@example", "a@@example.invalid", "a b@example.invalid"])
func secureProfileRejectsMalformedEmail(_ email: String) {
    var profile = syntheticSecureProfile()
    profile.email = email
    #expect(profile.validationIssues(at: validationDate).contains("Enter a valid email address."))
}

@Test(arguments: ["", "123456", "+1234567890123456", "+1A4165550100", "１２３４５６７８９"])
func secureProfileRejectsMalformedPhone(_ phone: String) {
    var profile = syntheticSecureProfile()
    profile.phone = phone
    #expect(profile.validationIssues(at: validationDate).contains("Enter a valid phone number."))
}

@Test(arguments: ["", "4111111111111112", "0000000000000000", "411111111111", "41111111111111111111", "４１１１１１１１１１１１１１１１", "4111a11111111111"])
func secureProfileRejectsMalformedCard(_ card: String) {
    var profile = syntheticSecureProfile()
    profile.cardNumber = card
    #expect(profile.validationIssues(at: validationDate).contains("Enter a valid card number."))
}

@Test(arguments: ["4111 1111 1111 1111", "4111-1111-1111-1111", "378282246310005"])
func secureProfileAcceptsValidSyntheticCardFormats(_ card: String) {
    var profile = syntheticSecureProfile()
    profile.cardNumber = card
    #expect(profile.validationIssues(at: validationDate).isEmpty)
}

@Test(arguments: ["", "12", "12345", "1a3", "１２３"])
func secureProfileRejectsMalformedCVV(_ cvv: String) {
    var profile = syntheticSecureProfile()
    profile.cvv = cvv
    #expect(profile.validationIssues(at: validationDate).contains("Enter a three or four digit security code."))
}

@Test func secureProfileExpiryBoundariesAndAddressCountries() {
    var profile = syntheticSecureProfile()
    for (month, year) in [("", "2035"), ("abc", "2035"), ("1", "35"), ("123", "2035"), ("1", "2O35")] {
        profile.expiryMonth = month
        profile.expiryYear = year
        #expect(profile.validationIssues(at: validationDate).contains("Enter an expiry month and four digit year."))
    }
    for (month, year) in [("00", "2035"), ("13", "2035"), ("09", "2026"), ("12", "2025")] {
        profile.expiryMonth = month
        profile.expiryYear = year
        #expect(profile.validationIssues(at: validationDate).contains("The card expiry date is invalid or expired."))
    }
    profile.expiryMonth = "10"
    profile.expiryYear = "2026"
    #expect(profile.validationIssues(at: validationDate).isEmpty)
    profile.expiryMonth = "11"
    #expect(profile.validationIssues(at: validationDate).isEmpty)
    profile.cvv = "1234"
    profile.billingCountry = "hk"
    profile.billingPostalCode = ""
    profile.billingRegion = ""
    #expect(profile.validationIssues(at: validationDate).isEmpty)
    for country in ["", "CAN", "12", "CÅ"] {
        profile.billingCountry = country
        #expect(profile.validationIssues(at: validationDate).contains("Choose a two letter billing country code."))
    }
}

@Test func secureVaultErrorsContainOnlyOperationAndStatus() {
    #expect(SecureVaultError.keychain(operation: "read", status: -25308).errorDescription?.contains("-25308") == true)
    #expect(SecureVaultError.malformedProfile.errorDescription?.contains("unreadable") == true)
    #expect(SecureVaultError.unexpectedKeychainResult.errorDescription?.contains("unexpected") == true)
}

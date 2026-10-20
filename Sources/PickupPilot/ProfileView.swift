import SwiftUI
import PilotCore

struct ProfileView: View {
    @Bindable var model: PilotModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Secure checkout details").font(.title2.bold()).padding()
            Form {
                Section("Pickup contact") {
                    TextField("Given name", text: $model.profile.givenName)
                    TextField("Family name", text: $model.profile.familyName)
                    TextField("Email", text: $model.profile.email)
                    TextField("Phone", text: $model.profile.phone)
                }
                Section("Payment card") {
                    TextField("Cardholder", text: $model.profile.cardholder)
                    TextField("Card number", text: $model.profile.cardNumber)
                    HStack {
                        TextField("Expiry month (MM)", text: $model.profile.expiryMonth)
                        TextField("Expiry year (YYYY)", text: $model.profile.expiryYear)
                        TextField("CVV", text: $model.profile.cvv)
                    }
                }
                Section("Billing address") {
                    TextField("Address line 1", text: $model.profile.billingLine1)
                    TextField("Address line 2 (optional)", text: $model.profile.billingLine2)
                    TextField("City", text: $model.profile.billingCity)
                    TextField("Province / state / region", text: $model.profile.billingRegion)
                    TextField("Postal / ZIP code", text: $model.profile.billingPostalCode)
                    TextField("Country (two-letter code)", text: $model.profile.billingCountry)
                }
                if !model.profile.validationIssues.isEmpty {
                    Section("Required before arming") {
                        ForEach(model.profile.validationIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.formStyle(.grouped).autocorrectionDisabled()
            HStack {
                Text("Saved only to this app's Keychain items.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.closeProfile() }.keyboardShortcut(.cancelAction)
                Button("Save to Keychain") { Task { await model.saveProfile() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 640, height: 720)
    }
}

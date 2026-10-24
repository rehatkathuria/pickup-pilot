import SwiftUI
import PilotCore

struct SecurityView: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    @State private var deleting = false
    var body: some View {
        PageTitle(title: "Secure checkout", subtitle: "Enter checkout details here on your Mac. They are saved in this app's Keychain items.")
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(model.hasSavedProfile ? "Checkout profile saved" : "Checkout profile needed", systemImage: model.hasSavedProfile ? "lock.fill" : "lock.open")
                    .font(.title2.bold())
                if !model.profileAccessStatus.isEmpty {
                    Text(model.profileAccessStatus).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("checkout-profile-access-status")
                }
                if !model.hasSavedProfile {
                    Button("Restore saved checkout profile", systemImage: "arrow.clockwise") {
                        Task { await model.restoreSavedCheckoutProfile() }
                    }.disabled(!model.canRestoreSavedProfile)
                        .accessibilityIdentifier("restore-saved-checkout-profile")
                    Text("Restore reads your existing Keychain profile without showing or changing its details, then reloads nearby stores. macOS may ask you to authorize this app locally.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.restoringSavedProfile {
                    ProgressView("Restoring saved checkout profile…").controlSize(.small)
                }
                Text("Contact, billing address, card number, expiry and CVV are stored in Keychain. Fields are visible while you edit. Your manual location is saved there with the profile.")
                HStack {
                    Button(model.hasSavedProfile ? "Edit secure details" : "Add secure details", systemImage: "key") { Task { await model.openProfile() } }.buttonStyle(.borderedProminent)
                    Button("Delete checkout profile", role: .destructive) { deleting = true }.disabled(!model.hasSavedProfile)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(model.coordinator.isArmed || model.armingAutomaticCheckout)
        GroupBox("Guest checkout session") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Checkout opens a dedicated Safari window and chooses Continue as Guest automatically. It never asks you to sign in. If guest checkout is unavailable or Apple requires a security challenge or bank verification, the attempt stops.")
                Text("Safari manages website data in its normal browser session. Pickup Pilot never exports Safari cookies or changes your other Safari windows. Verify a working page in Pickup Pilot’s Safari window before retrying. Verification never arms checkout or places an order.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Apple checkout", systemImage: "globe") { openWindow(id: "checkout") }
                    Button("Verify Safari session") { Task { await model.saveResolvedAppleSession() } }
                        .disabled(!model.canSaveResolvedAppleSession)
                }
                if !model.appleSessionRecoveryDetail.isEmpty {
                    Text(model.appleSessionRecoveryDetail).font(.callout).textSelection(.enabled)
                }
                Button("Reset Safari checkout window", systemImage: "trash") { Task { await model.clearSession() } }.disabled(model.coordinator.isArmed || model.armingAutomaticCheckout)
                Text("Allow Pickup Pilot to control Safari in System Settings → Privacy & Security → Automation. Enable Safari Settings → Developer → Automation → Allow JavaScript from Apple Events. Safari Settings → Advanced can show web developer features.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        GroupBox("Local build storage") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This local build uses the macOS login Keychain, with app-scoped access and cloud synchronization disabled. Access follows the login Keychain's lock and authorization settings. A provisioned developer-signed build can use the stricter Data Protection Keychain implementation included in the source.")
                Text("The app does not write payment details to preferences, activity logs or reports. Secrets exist temporarily in memory and in Apple's checkout page while needed. macOS may request Keychain authorization after rebuilding the app.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        Text("The order journal stays locked after a confirmed or uncertain submission. Use Activity & order to reconcile it before a deliberate reset.").font(.caption).foregroundStyle(.secondary)
        .confirmationDialog("Delete saved checkout details?", isPresented: $deleting) {
            Button("Delete profile", role: .destructive) { Task { await model.deleteProfile() } }
        } message: { Text("Your profile, including card and billing details, will be removed from this app's Keychain item.") }
    }
}

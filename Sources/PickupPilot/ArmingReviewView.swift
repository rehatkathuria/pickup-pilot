import SwiftUI
import PilotCore

struct ArmingReviewView: View {
    @Bindable var model: PilotModel
    let review: ArmingReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review before arming").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("Confirm the exact items, stores and limits Pickup Pilot will observe.")
                    .foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                SelectionSummaryView(plan: review.plan, profileSaved: review.profileSaved, title: "This monitoring plan")
                    .padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirming permits one pickup order within these limits. Guest checkout pauses for payment confirmation in the app. If guest checkout cannot continue, the attempt stops.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelArmingReview() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.armingAutomaticCheckout { ProgressView().controlSize(.small).accessibilityLabel("Validating monitoring plan") }
                    Button(model.armingAutomaticCheckout ? "Validating…" : "Confirm and arm", systemImage: "bolt.shield") {
                        Task { await model.confirmArmingReview(id: review.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.armingAutomaticCheckout || model.pendingArmingReview?.id != review.id)
                }
            }.padding(20)
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 480, idealHeight: 640)
    }
}

import Foundation
import PilotCore

/// A review capability contains only the selected public shopping scope and saved-profile status.
/// Contact, payment and session values never enter this presentation model.
struct ArmingReview: Identifiable, Equatable {
    let id: UUID
    let plan: MonitoringPlan
    let profileSaved: Bool
    init(id: UUID = UUID(), plan: MonitoringPlan, profileSaved: Bool) {
        self.id = id
        self.plan = plan
        self.profileSaved = profileSaved
    }
}

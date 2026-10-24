# Pickup Pilot coverage

Measurement recorded **October 17, 2026**: **retained Safari release Debug suite plus asserted disarmed app launch**. This is a historical release measurement, not a new repository-publication test run.

Whole production Swift app: **6541/6859 executable lines (95.36%)**. The requested 100% whole-app target is **not yet met**.

Regions: **3232/3637 (88.86%)**.
Functions: **967/1095 (88.31%)**.

Scope: every production Swift file under Sources/PilotCore and Sources/PickupPilot is listed and checked against the filesystem inventory. Executable-line totals cover all counters emitted by LLVM; the static JavaScript literal has no Swift counters and is explicitly listed as an unmeasured asset. No production file exclusions. SwiftUI, platform wrappers, lifecycle and checkout integration remain in the denominator. Test code, SDK code and build scripts are outside this Swift production scope. Swift regions are not a JavaScript or browser branch metric.

Embedded checkout JavaScript is exercised separately in native WebKit fixtures. LLVM emits no source-counter entry for its static string-literal file and does not measure JavaScript branches. This asset is listed below rather than assigned a fabricated denominator or a 100% score; no JavaScript coverage percentage is claimed.

| File | Covered lines | Executable lines | Percent |
|---|---:|---:|---:|
| Sources/PickupPilot/ActivityView.swift | 143 | 163 | 87.73% |
| Sources/PickupPilot/AppleCheckoutDriver.swift | 430 | 445 | 96.63% |
| Sources/PickupPilot/AppleCheckoutPage.swift | 491 | 498 | 98.59% |
| Sources/PickupPilot/AppleCheckoutScripts.swift | n/a | n/a | Unmeasured JS asset |
| Sources/PickupPilot/AppleCheckoutTiming.swift | 12 | 13 | 92.31% |
| Sources/PickupPilot/ArmingReview.swift | 5 | 5 | 100.00% |
| Sources/PickupPilot/ArmingReviewView.swift | 89 | 100 | 89.00% |
| Sources/PickupPilot/CheckoutDiagnosticsView.swift | 92 | 103 | 89.32% |
| Sources/PickupPilot/CheckoutPageDiagnostics.swift | 61 | 61 | 100.00% |
| Sources/PickupPilot/CheckoutRehearsal.swift | 229 | 247 | 92.71% |
| Sources/PickupPilot/CheckoutRehearsalWindow.swift | 108 | 113 | 95.58% |
| Sources/PickupPilot/CheckoutWindow.swift | 118 | 135 | 87.41% |
| Sources/PickupPilot/LocationService.swift | 146 | 146 | 100.00% |
| Sources/PickupPilot/MainView.swift | 355 | 390 | 91.03% |
| Sources/PickupPilot/MenuContent.swift | 12 | 18 | 66.67% |
| Sources/PickupPilot/MonitoringDisplayFormat.swift | 17 | 18 | 94.44% |
| Sources/PickupPilot/MonitoringObservationView.swift | 186 | 186 | 100.00% |
| Sources/PickupPilot/ObservedStoreRow.swift | 61 | 61 | 100.00% |
| Sources/PickupPilot/PickupPilotApp.swift | 75 | 96 | 78.12% |
| Sources/PickupPilot/PilotModel.swift | 580 | 604 | 96.03% |
| Sources/PickupPilot/ProfileView.swift | 148 | 151 | 98.01% |
| Sources/PickupPilot/SafariAppleCheckoutPage.swift | 296 | 361 | 81.99% |
| Sources/PickupPilot/SafariAutomation.swift | 364 | 379 | 96.04% |
| Sources/PickupPilot/SafariCheckoutStatusView.swift | 39 | 41 | 95.12% |
| Sources/PickupPilot/SafariValidation.swift | 34 | 35 | 97.14% |
| Sources/PickupPilot/ScheduleView.swift | 116 | 117 | 99.15% |
| Sources/PickupPilot/SecurityView.swift | 115 | 131 | 87.79% |
| Sources/PickupPilot/SelectionSummaryView.swift | 197 | 200 | 98.50% |
| Sources/PickupPilot/StoreSetupView.swift | 388 | 405 | 95.80% |
| Sources/PickupPilot/StoreTravelService.swift | 151 | 153 | 98.69% |
| Sources/PilotCore/CheckoutContract.swift | 71 | 71 | 100.00% |
| Sources/PilotCore/CheckoutSnapshot.swift | 138 | 138 | 100.00% |
| Sources/PilotCore/InventoryClient.swift | 72 | 72 | 100.00% |
| Sources/PilotCore/InventoryHTTP.swift | 71 | 71 | 100.00% |
| Sources/PilotCore/KeychainVault.swift | 108 | 108 | 100.00% |
| Sources/PilotCore/LocationResolution.swift | 62 | 62 | 100.00% |
| Sources/PilotCore/Market.swift | 27 | 27 | 100.00% |
| Sources/PilotCore/MonitoringCoordinator.swift | 398 | 398 | 100.00% |
| Sources/PilotCore/MonitoringPlan.swift | 6 | 6 | 100.00% |
| Sources/PilotCore/PilotPreferences.swift | 90 | 90 | 100.00% |
| Sources/PilotCore/PreferencesStore.swift | 11 | 11 | 100.00% |
| Sources/PilotCore/ProductCatalogClient.swift | 177 | 178 | 99.44% |
| Sources/PilotCore/ProductVariant.swift | 28 | 28 | 100.00% |
| Sources/PilotCore/PurchaseJournal.swift | 19 | 19 | 100.00% |
| Sources/PilotCore/RetailStore.swift | 8 | 8 | 100.00% |
| Sources/PilotCore/RetryPolicy.swift | 13 | 13 | 100.00% |
| Sources/PilotCore/SecureProfile.swift | 134 | 134 | 100.00% |
| Sources/PilotCore/SecureVault.swift | 10 | 10 | 100.00% |
| Sources/PilotCore/SingleInstanceLock.swift | 10 | 10 | 100.00% |
| Sources/PilotCore/StoreTravelEstimate.swift | 30 | 30 | 100.00% |

Remaining gaps include native SwiftUI control callbacks and app lifecycle/error presentation paths. Offscreen rendering, state-machine tests and a launch check do not prove desktop interactions. Earlier desktop automation and in-process input experiments were incomplete and were not reported as passing full interaction tests.

This metric does not prove live paid checkout. See [validation notes](VALIDATION.md) for read-only Apple integration, synthetic Keychain/checkout tests and limitations.

// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "PickupPilot",
    platforms: [.macOS(.v15)],
    products: [.library(name: "PilotCore", targets: ["PilotCore"]), .executable(name: "PickupPilot", targets: ["PickupPilot"])],
    targets: [
        .target(name: "PilotCore"),
        .executableTarget(name: "PickupPilot", dependencies: ["PilotCore"]),
        .testTarget(name: "PilotCoreTests", dependencies: ["PilotCore"]),
        .testTarget(name: "PickupPilotTests", dependencies: ["PickupPilot", "PilotCore"])
    ],
    swiftLanguageModes: [.v6]
)

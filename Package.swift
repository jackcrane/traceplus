// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TracePlus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TracePlus", targets: ["TracePlus"]),
        .executable(name: "TelemetryFountain", targets: ["TelemetryFountain"])
    ],
    targets: [
        .target(name: "TelemetryKit"),
        .executableTarget(name: "TracePlus", dependencies: ["TelemetryKit"]),
        .executableTarget(name: "TelemetryFountain", dependencies: ["TelemetryKit"]),
        .testTarget(name: "TelemetryKitTests", dependencies: ["TelemetryKit"]),
        .testTarget(name: "TracePlusTests", dependencies: ["TracePlus"])
    ]
)

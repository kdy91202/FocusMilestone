// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FocusMilestone",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FocusMilestone", targets: ["FocusMilestone"])
    ],
    targets: [
        .executableTarget(name: "FocusMilestone")
    ]
)

// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Coolant",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CoolantCore", dependencies: ["CSMC"]),
        .executableTarget(name: "coolantd", dependencies: ["CoolantCore"]),
        .executableTarget(name: "coolantctl", dependencies: ["CoolantCore"]),
        .executableTarget(name: "Coolant", dependencies: ["CoolantCore"]),
        .testTarget(name: "CoolantCoreTests", dependencies: ["CoolantCore"]),
    ]
)

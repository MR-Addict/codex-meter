// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AIMeter", targets: ["AIMeter"])],
    targets: [
        .target(name: "MeterCore"),
        .executableTarget(name: "AIMeter", dependencies: ["MeterCore"]),
        .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
        .testTarget(name: "MeterModelTests", dependencies: ["AIMeter", "MeterCore"]),
    ]
)

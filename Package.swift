// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CodexMeter", platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexMeter", targets: ["CodexMeter"])],
    targets: [.target(name: "MeterCore"), .executableTarget(name: "CodexMeter", dependencies: ["MeterCore"]),
              .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"]),
              .testTarget(name: "MeterModelTests", dependencies: ["CodexMeter", "MeterCore"])])

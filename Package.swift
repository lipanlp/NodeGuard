// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NodeGuard",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NodeGuard", targets: ["NodeGuard"])],
    dependencies: [.package(path: "Vendor/Yams")],
    targets: [
        .target(name: "CProcess", publicHeadersPath: "include"),
        .target(name: "NodeGuardCore", dependencies: ["Yams", "CProcess"]),
        .executableTarget(name: "NodeGuard", dependencies: ["NodeGuardCore"]),
        .executableTarget(name: "NodeGuardTests", dependencies: ["NodeGuardCore"], path: "Tests/NodeGuardCoreTests")
    ]
)

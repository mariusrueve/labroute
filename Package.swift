// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LabRoute",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LabRouteCore", targets: ["LabRouteCore"]),
        .library(name: "LabRouteServices", targets: ["LabRouteServices"]),
        .executable(name: "LabRouteApp", targets: ["LabRouteApp"]),
        .executable(name: "labroute", targets: ["LabRouteCLI"]),
        .executable(name: "LabRouteAskPass", targets: ["LabRouteAskPass"]),
    ],
    targets: [
        .target(name: "LabRouteCore", resources: [.process("Resources")]),
        .target(name: "LabRouteServices", dependencies: ["LabRouteCore"]),
        .executableTarget(name: "LabRouteApp", dependencies: ["LabRouteCore", "LabRouteServices"]),
        .executableTarget(name: "LabRouteCLI", dependencies: ["LabRouteCore", "LabRouteServices"]),
        .executableTarget(name: "LabRouteAskPass", dependencies: ["LabRouteServices"]),
        .testTarget(name: "LabRouteCoreTests", dependencies: ["LabRouteCore"]),
        .testTarget(name: "LabRouteServicesTests", dependencies: ["LabRouteServices"]),
    ]
)

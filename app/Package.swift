// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dmbar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Dmbar",
            path: "Sources/Dmbar",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DmbarTests",
            dependencies: ["Dmbar"],
            path: "Tests/DmbarTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)

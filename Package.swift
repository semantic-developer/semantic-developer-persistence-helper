// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SemanticDeveloperPersistenceHelper",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SharedModels", targets: ["SharedModels"]),
        .library(name: "HostConfig", targets: ["HostConfig"]),
        .library(name: "RemotePersistenceProtocol", targets: ["RemotePersistenceProtocol"]),
        .executable(name: "semantic-developer-helper", targets: ["RemotePersistenceHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.14.0"),
    ],
    targets: [
        .target(
            name: "SharedModels"
        ),
        .target(
            name: "HostConfig",
            dependencies: ["SharedModels"]
        ),
        .target(
            name: "RemotePersistenceProtocol",
            dependencies: ["SharedModels", "HostConfig"]
        ),
        .executableTarget(
            name: "RemotePersistenceHelper",
            dependencies: ["SharedModels", "RemotePersistenceProtocol"]
        ),
        .testTarget(
            name: "RemotePersistenceHelperTests",
            dependencies: [
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevStore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "devstore", targets: ["devstore"]),
        .executable(name: "devstore-mcp", targets: ["devstore-mcp"]),
        .library(name: "DevStoreCore", targets: ["DevStoreCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "DevStoreCore"),
        .target(name: "DevStoreMCP", dependencies: ["DevStoreCore"]),
        .executableTarget(name: "devstore-mcp", dependencies: ["DevStoreMCP"]),
        .executableTarget(
            name: "devstore",
            dependencies: [
                "DevStoreCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DevStoreCoreTests", dependencies: ["DevStoreCore", "DevStoreMCP"]),
    ]
)

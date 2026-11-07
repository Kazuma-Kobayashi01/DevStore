// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevStore",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "devstore", targets: ["devstore"]),
        .executable(name: "devstore-mcp", targets: ["devstore-mcp"]),
        .executable(name: "DevStoreApp", targets: ["DevStoreApp"]),
        .library(name: "DevStoreCore", targets: ["DevStoreCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "DevStoreCore"),
        .target(name: "DevStoreMCP", dependencies: ["DevStoreCore"]),
        .executableTarget(name: "devstore-mcp", dependencies: ["DevStoreMCP"]),
        .executableTarget(name: "DevStoreApp", dependencies: ["DevStoreCore"]),
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

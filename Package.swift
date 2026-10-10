// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StupidMirror",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "StupidMirrorApp", targets: ["StupidMirrorApp"]),
        .executable(name: "StupidMirrorMCPBridge", targets: ["StupidMirrorMCPBridge"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "StupidMirrorConnection",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "StupidMirrorBridgeCore",
            dependencies: ["StupidMirrorConnection", .product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "StupidMirrorMCPBridge",
            dependencies: ["StupidMirrorBridgeCore", "StupidMirrorConnection", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "StupidMirrorBridgeTests",
            dependencies: ["StupidMirrorBridgeCore", "StupidMirrorConnection", .product(name: "MCP", package: "swift-sdk")]
        ),
        .binaryTarget(
            name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"
        ),
        .executableTarget(
            name: "StupidMirrorApp",
            dependencies: [
                "StupidMirrorConnection",
                "libsrt",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            path: "Sources/StupidMirrorApp"
        ),
        .testTarget(
            name: "StupidMirrorAppTests",
            dependencies: [
                "StupidMirrorApp",
                "libsrt",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/StupidMirrorAppTests"
        )
    ]
)

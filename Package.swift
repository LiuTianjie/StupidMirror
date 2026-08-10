// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StupidMirror",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "StupidMirrorApp", targets: ["StupidMirrorApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.11.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "StupidMirrorApp",
            dependencies: [
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
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/StupidMirrorAppTests"
        )
    ]
)

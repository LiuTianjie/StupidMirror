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
    targets: [
        .executableTarget(
            name: "StupidMirrorApp",
            path: "Sources/StupidMirrorApp"
        ),
        .testTarget(
            name: "StupidMirrorAppTests",
            dependencies: ["StupidMirrorApp"],
            path: "Tests/StupidMirrorAppTests"
        )
    ]
)

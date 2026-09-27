// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TakelyKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProjectKit", targets: ["ProjectKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
    ],
    targets: [
        .target(name: "ProjectKit"),
        .target(name: "CaptureKit", dependencies: ["ProjectKit"]),
        .target(name: "RenderKit", dependencies: ["ProjectKit"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit", "TestSupport"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit", "CaptureKit", "TestSupport"]),
    ]
)

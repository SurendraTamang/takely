// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TakelyKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProjectKit", targets: ["ProjectKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "TakelyControl", targets: ["TakelyControl"]),
        .library(name: "ShareKit", targets: ["ShareKit"]),
        .executable(name: "takely", targets: ["takely"]),
        .library(name: "TakelyMCPKit", targets: ["TakelyMCPKit"]),
        .executable(name: "takely-mcp", targets: ["takely-mcp"]),
    ],
    dependencies: [
        // The official Model Context Protocol SDK (MIT/Apache-2.0), for the MCP server AI agents use.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(name: "ProjectKit"),
        // WebRTC AEC3 + a C wrapper, prebuilt by scripts/build-webrtc-apm.sh (BSD-3; licenses in Vendor/webrtc-aec).
        .binaryTarget(name: "WebRTCAEC", path: "Vendor/WebRTCAEC.xcframework"),
        .target(
            name: "CaptureKit", dependencies: ["ProjectKit", "WebRTCAEC"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreFoundation")]),
        .target(name: "RenderKit", dependencies: ["ProjectKit"]),
        .target(name: "AppCore", dependencies: ["ProjectKit", "CaptureKit", "RenderKit", "TakelyControl"]),
        // Automation transport (CLI ↔ app); Foundation only, so the CLI stays small.
        .target(name: "TakelyControl"),
        // Uploading to the user's own S3-compatible bucket (R2, S3, B2, MinIO) with a player page.
        .target(name: "ShareKit", dependencies: ["ProjectKit"]),
        .executableTarget(name: "takely", dependencies: ["TakelyControl"]),
        // `takely-mcp`: an MCP server (stdio) over the same control socket as the CLI, for AI agents.
        .target(name: "TakelyMCPKit", dependencies: ["TakelyControl", "ProjectKit", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(
            name: "takely-mcp", dependencies: ["TakelyMCPKit", "TakelyControl", .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit", "TestSupport", "WebRTCAEC"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit", "CaptureKit", "TestSupport"]),
        .testTarget(
            name: "AppCoreTests", dependencies: ["AppCore", "CaptureKit", "ProjectKit", "RenderKit", "TestSupport", "TakelyControl"]),
        .testTarget(name: "TakelyControlTests", dependencies: ["TakelyControl"]),
        .testTarget(name: "ShareKitTests", dependencies: ["ShareKit", "ProjectKit", "RenderKit", "TestSupport"]),
        .testTarget(
            name: "TakelyMCPKitTests",
            dependencies: ["TakelyMCPKit", "TakelyControl", "ProjectKit", .product(name: "MCP", package: "swift-sdk")]),
    ]
)

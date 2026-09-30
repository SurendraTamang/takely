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
    ],
    targets: [
        .target(name: "ProjectKit"),
        // WebRTC AEC3 + a C wrapper, prebuilt by scripts/build-webrtc-apm.sh (BSD-3; licenses in Vendor/webrtc-aec).
        .binaryTarget(name: "WebRTCAEC", path: "Vendor/WebRTCAEC.xcframework"),
        .target(
            name: "CaptureKit", dependencies: ["ProjectKit", "WebRTCAEC"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreFoundation")]),
        .target(name: "RenderKit", dependencies: ["ProjectKit"]),
        .target(name: "AppCore", dependencies: ["ProjectKit", "CaptureKit", "RenderKit"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit", "TestSupport", "WebRTCAEC"]),
        .testTarget(name: "RenderKitTests", dependencies: ["RenderKit", "CaptureKit", "TestSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "CaptureKit", "ProjectKit", "RenderKit", "TestSupport"]),
    ]
)

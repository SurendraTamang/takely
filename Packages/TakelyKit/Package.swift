// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TakelyKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProjectKit", targets: ["ProjectKit"])
    ],
    targets: [
        .target(name: "ProjectKit"),
        .testTarget(name: "ProjectKitTests", dependencies: ["ProjectKit"]),
    ]
)

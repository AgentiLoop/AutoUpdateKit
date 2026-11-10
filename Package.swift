// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoUpdateKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutoUpdateKit", targets: ["AutoUpdateKit"]),
    ],
    targets: [
        .target(name: "AutoUpdateKit"),
        .testTarget(name: "AutoUpdateKitTests", dependencies: ["AutoUpdateKit"]),
    ]
)

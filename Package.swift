// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "optiview-lens-sdk",
    platforms: [
        .iOS(.v13),
        .tvOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(name: "LensSDK", targets: ["LensSDK"]),
        .library(name: "LensSDKDev", targets: ["LensSDKDev"]),
    ],
    targets: [
        .target(name: "LensSDK"),
        .target(name: "LensSDKDev", dependencies: ["LensSDK"]),
        .testTarget(name: "LensSDKTests", dependencies: ["LensSDK", "LensSDKDev"]),
    ]
)

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
        .library(name: "LensSDKDev", targets: ["LensSDKDev", "LensSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "LensSDK",
            url: "https://github.com/Dolby-OptiView/optiview-lens-sdk-swift/releases/download/0.7.0/LensSDK.xcframework.zip",
            checksum: "ce72db52e65c76804a6712a27d6c376af91203aac5f14319c22a5a0ff95c8cfb"
        ),
        .binaryTarget(
            name: "LensSDKDev",
            url: "https://github.com/Dolby-OptiView/optiview-lens-sdk-swift/releases/download/0.7.0/LensSDKDev.xcframework.zip",
            checksum: "ba3b67f9c8033b470b885962c64e5af71de2f6901f623e223c641097fa87333a"
        ),
    ]
)

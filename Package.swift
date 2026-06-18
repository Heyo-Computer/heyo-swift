// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeyoSDK",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HeyoSDK", targets: ["HeyoSDK"])
    ],
    targets: [
        .target(
            name: "HeyoSDK",
            path: "Sources/HeyoSDK"
        ),
        .testTarget(
            name: "HeyoSDKTests",
            dependencies: ["HeyoSDK"],
            path: "Tests/HeyoSDKTests"
        )
    ]
)

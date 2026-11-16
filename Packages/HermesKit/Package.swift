// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "HermesKit", targets: ["HermesKit"])],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
    ],
    targets: [
        .target(name: "HermesKit", dependencies: [.product(name: "Citadel", package: "Citadel")]),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"]),
    ]
)

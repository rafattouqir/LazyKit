// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LazyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LazyKit",
            targets: ["LazyKit"]
        )
    ],
    targets: [
        .target(name: "LazyKit"),
        .testTarget(
            name: "LazyKitTests",
            dependencies: ["LazyKit"]
        )
    ]
)

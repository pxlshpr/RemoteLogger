// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RemoteLogger",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RemoteLogger",
            targets: ["RemoteLogger"]
        ),
    ],
    targets: [
        .target(name: "RemoteLogger"),
    ]
)

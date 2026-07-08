// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SingReadyAI",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SingReadyAISharedKit",
            targets: ["SingReadyAISharedKit"]
        )
    ],
    targets: [
        .target(
            name: "SingReadyAISharedKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SingReadyAISharedKitTests",
            dependencies: ["SingReadyAISharedKit"]
        )
    ]
)

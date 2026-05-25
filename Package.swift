// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShakeShelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShakeShelfCore", targets: ["ShakeShelfCore"]),
        .executable(name: "ShakeShelf", targets: ["ShakeShelf"])
    ],
    targets: [
        .target(name: "ShakeShelfCore"),
        .executableTarget(
            name: "ShakeShelf",
            dependencies: ["ShakeShelfCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "ShakeShelfCoreTests",
            dependencies: ["ShakeShelfCore"]
        )
    ]
)

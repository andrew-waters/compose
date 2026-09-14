// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "compose",
    platforms: [.macOS("26")],
    products: [
        .library(name: "ComposeModel", targets: ["ComposeModel"]),
        .library(name: "ComposeParser", targets: ["ComposeParser"]),
        .library(name: "ComposePlanner", targets: ["ComposePlanner"]),
    ],
    dependencies: [
        // The only third-party dependency, and deliberately so: it lands in Orchard's
        // dependency graph too, where apple/container already pulls the same version.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1")
    ],
    targets: [
        .target(name: "ComposeModel"),
        .target(
            name: "ComposeParser",
            dependencies: ["ComposeModel", .product(name: "Yams", package: "Yams")]
        ),
        .target(name: "ComposePlanner", dependencies: ["ComposeModel"]),
        .testTarget(
            name: "ComposeParserTests",
            dependencies: ["ComposeParser"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ComposePlannerTests",
            dependencies: ["ComposePlanner", "ComposeParser"]
        ),
    ]
)

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "compose",
    platforms: [.macOS("26")],
    products: [
        .library(name: "ComposeModel", targets: ["ComposeModel"]),
        .library(name: "ComposeParser", targets: ["ComposeParser"]),
        .library(name: "ComposePlanner", targets: ["ComposePlanner"]),
        .executable(name: "compose", targets: ["compose"]),
    ],
    dependencies: [
        // The libraries take one dependency, and deliberately so: it lands in Orchard's
        // dependency graph too, where apple/container already pulls the same version.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        // The plugin takes two more. Both stay inside the executable target: a package that
        // makes plans has no business linking a client for the thing that carries them out.
        .package(url: "https://github.com/apple/container.git", from: "1.4.1"),
        .package(url: "https://github.com/apple/containerization.git", from: "0.45.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
    ],
    targets: [
        .target(name: "ComposeModel"),
        .target(
            name: "ComposeParser",
            dependencies: ["ComposeModel", .product(name: "Yams", package: "Yams")]
        ),
        .target(name: "ComposePlanner", dependencies: ["ComposeModel"]),
        .executableTarget(
            name: "compose",
            dependencies: [
                "ComposeModel",
                "ComposeParser",
                "ComposePlanner",
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // The plugin's config file is installed next to the binary by `make install`, not
            // bundled into it, so the target must be told to leave it alone.
            exclude: ["config.toml"]
        ),
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

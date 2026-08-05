// swift-tools-version: 6.0
import PackageDescription

// Two targets rather than one. SteleKit holds the decisions — credential-file location and
// permission rules, host selection, request construction, response decoding — and depends on
// nothing, so the tests can exercise them as pure functions instead of spawning a process and
// scraping its output. The executable is ArgumentParser wiring and printing only.
let package = Package(
    name: "stele",
    // Only a floor for the Apple platforms; the package builds and runs on Linux, which SwiftPM
    // does not express here. Matches what the toolchain needs for modern Foundation and
    // structured concurrency without pinning anything newer than necessary.
    platforms: [.macOS(.v13)],
    products: [
        // The binary is `stele`, not `stelectl` — it is the only client, so there is nothing for
        // a `ctl` suffix to distinguish it from.
        .executable(name: "stele", targets: ["stele"]),
        .library(name: "SteleKit", targets: ["SteleKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // No dependencies, deliberately: ArgumentParser belongs to the presentation layer, and a
        // library that imports it starts growing `@Option` properties instead of parameters.
        .target(name: "SteleKit"),
        .executableTarget(
            name: "stele",
            dependencies: [
                "SteleKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SteleKitTests", dependencies: ["SteleKit"]),
    ]
)

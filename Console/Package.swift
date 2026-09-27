// swift-tools-version: 6.0
import PackageDescription

/// The consent console.
///
/// A separate package from the server, and separately installed: the server ENFORCES and
/// this CONSENTS, and the whole design rests on those being two programs rather than one.
/// A menu-bar accessory, assembled from this binary without Xcode, per the decision
/// recorded in `blueprint.json` B2.
///
/// `macOS 15` matches the server, because the two share the console channel's protocol
/// types and must agree about what a wire frame is.
let package = Package(
    name: "ExactMacConsole",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "ExactMacConsole",
            targets: ["ExactMacConsole"],
        ),
    ],
    targets: [
        .executableTarget(
            name: "ExactMacConsole",
            path: "Sources/ExactMacConsole",
            resources: [
                // The design tokens, copied in rather than re-typed, so the app cannot
                // drift from the file the .fig is generated from.
                .copy("Resources/tokens.json"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
                .unsafeFlags(["-warnings-as-errors"]),
            ],
        ),
        .testTarget(
            name: "ExactMacConsoleTests",
            dependencies: ["ExactMacConsole"],
            path: "Tests/ExactMacConsoleTests",
        ),
    ],
)

// swift-tools-version: 6.0
import PackageDescription

/// The ExactMac application: one program, two halves.
///
/// THE PACKAGE BOUNDARY IS A BUILD UNIT, NOT A PROCESS BOUNDARY. This is a separate
/// SwiftPM package from the server for dependency hygiene, and at RUNTIME IT IS ONE
/// PROCESS: this target links the server's library and hosts the gRPC server in its own
/// process, so the server ENFORCES and this CONSENTS as two halves of one binary with a
/// direct call between them. There is no console socket, no second executable, and no
/// launchd-managed peer process for consent to arrive over. An earlier revision of this
/// comment claimed the design "rests on those being two programs rather than one"; that
/// was the old shape and it is no longer true.
///
/// A menu-bar accessory, assembled from this binary without Xcode, per the decision
/// recorded in `blueprint.json` B2.
///
/// `macOS 15` matches the server because this target imports the server's own
/// authorization types rather than restating them: the request the operator is shown, the
/// options offered, and the answer given back are the server's own values, so there is
/// one definition of each rather than two that have to agree.
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
    dependencies: [
        // A local path dependency, not a URL: the server is in this repository and the two
        // are released together. The product is the server's LIBRARY product, so the
        // server's sources compile into this executable rather than being run alongside it.
        .package(name: "ExactMacServer", path: "../Server"),
    ],
    targets: [
        .executableTarget(
            name: "ExactMacConsole",
            dependencies: [
                .product(name: "ExactMacServer", package: "ExactMacServer"),
            ],
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

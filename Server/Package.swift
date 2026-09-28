// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// NOTE: gRPC Swift 2 requires macOS 15+ for its Swift 6 concurrency features.
/// The deployment target is set to macOS 15 to ensure compatibility.
let package = Package(
    name: "ExactMacServer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // The server is a LIBRARY so the GUI app in `Console/` can host the exact same server
        // code in-process and present consent itself. The product name is deliberately
        // `ExactMacServer` so a dependent package declares `.product(name: "ExactMacServer",
        // package: "Server")` and nothing else in the API is renamed.
        .library(
            name: "ExactMacServer",
            targets: ["ExactMacServer"],
        ),
        // The standalone headless binary, for running the server without a GUI. The product
        // name is the executable's name, so it cannot also be `ExactMacServer` — that name is
        // the library product above, and two products in one package may not share a name.
        // This is the only place the two variants disagree, and it is a name.
        .executable(
            name: "exactmac-server",
            targets: ["ExactMacServerHeadless"],
        ),
    ],
    dependencies: [
        // gRPC Swift 2 core, transport, and Protobuf integration
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.1"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.7.0"),
        .package(url: "https://github.com/grpc/grpc-swift-extras.git", from: "2.2.0"),
        // The server owns its own Unix-socket accept loop so it can read the kernel's peer
        // evidence at accept time, and `ServerBootstrap` — the only way to hand SwiftNIO a
        // connected socket — lives in NIOPosix. The version requirement is deliberately
        // wide and the resolved file still pins the exact revision.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(name: "ExactMac", path: "../"),
    ],
    targets: [
        // Target for the generated Swift Protobuf and gRPC stubs
        // This makes the generated code available to the server target
        .target(
            name: "ExactMacProto",
            dependencies: [
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/ExactMacProto",
            exclude: [],
            sources: ["exactmac/", "google/"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
                .unsafeFlags(["-warnings-as-errors"]),
            ],
        ),
        // A LIBRARY, not an executable. This target is entered by two hosts — the GUI app in
        // `Console/` and the headless `ExactMacServerHeadless` below — so it must not own a
        // top-level entry, and a file named `main.swift` is illegal here for the same reason.
        // The target name is unchanged because 43 test files do `@testable import ExactMacServer`.
        .target(
            name: "ExactMacServer",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "GRPCReflectionService", package: "grpc-swift-extras"),
                .product(name: "GRPCHealthService", package: "grpc-swift-extras"),
                "ExactMac",
                "ExactMacProto", // Add dependency on the generated protos
            ],
            path: "Sources/ExactMacServer",
            resources: [
                .copy("DescriptorSets"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
                .unsafeFlags(["-warnings-as-errors"]),
            ],
        ),
        // The headless entry point. Deliberately thin: it translates a startup throw into a
        // clean exit rather than a top-level trap, and then calls the library's `main()`.
        .executableTarget(
            name: "ExactMacServerHeadless",
            dependencies: [
                "ExactMacServer",
                "ExactMac",
            ],
            path: "Sources/ExactMacServerHeadless",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
                .unsafeFlags(["-warnings-as-errors"]),
            ],
        ),
        .testTarget(
            name: "ExactMacServerTests",
            dependencies: [
                "ExactMacServer",
                "ExactMacProto",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCInProcessTransport", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
        ),
    ],
)

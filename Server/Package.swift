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
        .executable(
            name: "ExactMacServer",
            targets: ["ExactMacServer"],
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
        .executableTarget(
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

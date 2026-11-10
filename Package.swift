// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-sse",
    platforms: [
        .macOS("26.2"),
        .iOS("26.2"),
    ],
    products: [
        .library(name: "SSE", targets: ["SSE"]),
    ],
    // A trait selects the web framework that the `SSE` module supports.
    // SwiftPM does not resolve the framework of a trait that is not enabled.
    // The `Vapor` trait needs Swift 6.4, because Vapor 5 needs it.
    traits: [
        .trait(name: "Vapor", description: "Adds the SSE API for Vapor 5."),
        .trait(name: "Hummingbird", description: "Adds the SSE API for Hummingbird 2."),
        .default(enabledTraits: ["Vapor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.7.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "5.0.0-beta.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Only the Hummingbird tests use AsyncHTTPClient. They use it to read a response as a stream.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    ],
    targets: [
        .target(
            name: "SSE",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Vapor", package: "vapor", condition: .when(traits: ["Vapor"])),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Hummingbird"])),
            ]
        ),
        .testTarget(
            name: "SSETests",
            dependencies: [
                "SSE",
                .product(name: "VaporTesting", package: "vapor", condition: .when(traits: ["Vapor"])),
                .product(name: "HummingbirdTesting", package: "hummingbird", condition: .when(traits: ["Hummingbird"])),
                .product(name: "AsyncHTTPClient", package: "async-http-client", condition: .when(traits: ["Hummingbird"])),
            ]
        ),
    ]
)

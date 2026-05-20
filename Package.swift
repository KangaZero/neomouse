// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "neomouse",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        //SQLite toolkit
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.4"),
        // Apple's swift-testing — bundled with full Xcode but not the bare
        // Command Line Tools install, so declare explicitly to keep tests
        // portable across toolchains.
        .package(url: "https://github.com/swiftlang/swift-testing", exact: "6.3.1"),
    ],

    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "neomouse",
            dependencies: [
                "neomouseDB",
                "neomouseUtils",
                "neomouseConfig",
                "neomouseTypes",
            ],
            path: "Sources/neomouse",
        ),
        .target(
            name: "neomouseDB",
            dependencies: [
                "neomouseUtils",
                "neomouseTypes",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/neomouseDB",
        ),
        .target(
            name: "neomouseUtils",
            dependencies: ["neomouseTypes"],
            path: "Sources/neomouseUtils",
        ),
        .target(
            name: "neomouseConfig",
            dependencies: [
                "neomouseUtils",
                "neomouseTypes",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/neomouseConfig",
        ),
        .target(
            name: "neomouseTypes",
            dependencies: [],
            path: "Sources/neomouseTypes",
        ),
        .testTarget(
            name: "neomouseTests",
            dependencies: [
                "neomouse",
                "neomouseTypes",
                "neomouseDB", "neomouseUtils", "neomouseConfig",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/neomouseTests",
        ),
    ],
    swiftLanguageModes: [.v6]
)

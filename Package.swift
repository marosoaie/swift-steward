// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "swift-steward",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BuildLogKit", targets: ["BuildLogKit"]),
        .library(name: "DiffDiagnostics", targets: ["DiffDiagnostics"]),
        .executable(name: "git-diff-parser", targets: ["git-diff-parser"]),
    ],
    dependencies: [
        // GitDiffKit. Tagged versions only: SwiftPM rejects branch and
        // revision dependencies underneath a versioned package.
        .package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Chunk-to-line plumbing for the streaming log parsers; internal to
        // the package (not a product). The library keeps its own copy inside
        // GitDiffKit, so its public API stays diff-only.
        .target(
            name: "StreamParsing",
            swiftSettings: swiftSettings
        ),
        // Build/lint logs → diagnostics, with tool-specific parsers for
        // xcodebuild, SwiftLint, and SwiftFormat.
        .target(
            name: "BuildLogKit",
            dependencies: ["StreamParsing"],
            swiftSettings: swiftSettings
        ),
        // The join: which diagnostics land on lines a diff touches.
        .target(
            name: "DiffDiagnostics",
            dependencies: [
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "BuildLogKit",
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "git-diff-parser",
            dependencies: [
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "BuildLogKit",
                "DiffDiagnostics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftStewardTests",
            dependencies: [
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "BuildLogKit",
                "DiffDiagnostics",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)

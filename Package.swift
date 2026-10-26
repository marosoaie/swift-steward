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
    // GitDiffKit 0.2 needs the 26 releases, whose standard library has
    // `Span`; Linux has no floor.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BuildLogKit", targets: ["BuildLogKit"]),
        .library(name: "DiffDiagnostics", targets: ["DiffDiagnostics"]),
        .executable(name: "steward", targets: ["StewardCLI"]),
    ],
    dependencies: [
        // GitDiffKit. Tagged versions only: SwiftPM rejects branch and
        // revision dependencies underneath a versioned package.
        .package(url: "https://github.com/marosoaie/git-diff-parser.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // The GitHub client target only (decision 5). The generator itself
        // lives in Tooling/Package.swift, so packages that depend on this one
        // never build it.
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.4.0"),
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
        // The `steward` command. Not named after its product: a module
        // `steward` would collide with the planned `Steward` library module
        // on case-insensitive file systems.
        .executableTarget(
            name: "StewardCLI",
            dependencies: [
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "BuildLogKit",
                "DiffDiagnostics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        // The host seam: what Steward needs from the service hosting a pull
        // request, with no dependencies, so rules and fakes never pull in
        // the GitHub client.
        .target(
            name: "PullRequestHosting",
            swiftSettings: swiftSettings
        ),
        // The GitHub REST client, and GitHubHost, its PullRequestHosting
        // implementation. Generated/ is written by
        // Tooling/generate-github-api.sh from Specs/github and committed; CI
        // fails when it drifts from what the pipeline produces. The strict
        // settings hold for it too: the generator config and two spec fixes
        // keep it warning-free.
        .target(
            name: "GitHubAPI",
            dependencies: [
                "PullRequestHosting",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: swiftSettings
        ),
        // Steward, the pure-Swift Danger (docs/danger.md). Not a product
        // yet: so far it has the context rules see; the runner comes next.
        .target(
            name: "Steward",
            dependencies: [
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "PullRequestHosting",
                "GitHubAPI",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StewardTests",
            dependencies: [
                "Steward",
                .product(name: "GitDiffKit", package: "git-diff-parser"),
                "PullRequestHosting",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GitHubAPITests",
            dependencies: [
                "GitHubAPI",
                "PullRequestHosting",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                // The opt-in live tests' transport.
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            resources: [.copy("Fixtures")],
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

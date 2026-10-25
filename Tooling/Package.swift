// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

// Regeneration tooling for Sources/GitHubAPI/Generated. A separate package
// so the root manifest never depends on it: a Dangerfile package that depends
// on swift-steward must not build the generator or its dependencies.
let package = Package(
    name: "swift-steward-tooling",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Exact: the generator's output is committed, and the CI drift guard
        // compares against it, so a new generator version is a reviewed change.
        .package(url: "https://github.com/apple/swift-openapi-generator.git", exact: "1.14.2"),
        // Both already come with the generator.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // The spec-fix engine: decodes Specs/github/fixes.yaml and applies
        // it to the filtered description.
        .target(
            name: "GitHubSpecFixes",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "github-spec-fix",
            dependencies: [
                "GitHubSpecFixes",
                .product(name: "Yams", package: "Yams"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GitHubSpecFixesTests",
            dependencies: ["GitHubSpecFixes", .product(name: "Yams", package: "Yams")],
            swiftSettings: swiftSettings
        ),
    ]
)

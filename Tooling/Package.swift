// swift-tools-version: 6.2
import PackageDescription

// Tooling only: the root manifest never depends on this package, so a
// Dangerfile package that depends on swift-steward never builds the
// generator or its dependencies.
let package = Package(
    name: "swift-steward-tooling",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator.git", exact: "1.14.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        // Applies the reviewed spec fixes in Specs/github/Fixes to the
        // filtered document, before generation.
        .executableTarget(
            name: "github-spec-fix",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .testTarget(
            name: "GitHubSpecFixTests",
            dependencies: ["github-spec-fix", .product(name: "Yams", package: "Yams")]
        ),
    ]
)

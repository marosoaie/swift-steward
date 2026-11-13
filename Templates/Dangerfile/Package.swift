// swift-tools-version: 6.2
// The checks Steward runs on this repository's pull requests. It sits
// beside the repository's own package, not inside it, so it never joins the
// app's build. Quickstart:
// https://github.com/marosoaie/swift-steward/blob/main/docs/quickstart.md
import PackageDescription

let package = Package(
    name: "Dangerfile",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Steward 0.2.x, at the release Package.resolved pins: `swift package
        // update` takes its fixes. Under 0.x a minor release may break, so
        // moving to the next one is an edit here.
        .package(url: "https://github.com/marosoaie/swift-steward.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .executableTarget(
            name: "Dangerfile",
            dependencies: [.product(name: "Steward", package: "swift-steward")]
        ),
        .testTarget(
            name: "DangerfileTests",
            dependencies: ["Dangerfile", .product(name: "StewardTesting", package: "swift-steward")]
        ),
    ]
)

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
        // No release has Steward yet, so this follows swift-steward's main
        // branch, at the revision Package.resolved pins; `swift package
        // update` moves the pin. Once a release has it, replace
        // `branch: "main"` with `from:` and that version.
        .package(url: "https://github.com/marosoaie/swift-steward.git", branch: "main"),
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

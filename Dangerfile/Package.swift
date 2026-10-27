// swift-tools-version: 6.2
// The checks Steward runs on this repository's own pull requests, in
// pr.yml's tests-and-diagnostics job (docs/quickstart.md has the layout).
// Unlike a user's Dangerfile, it depends on the checkout it sits in, so
// every pull request is checked by its own Steward and no pin needs
// moving. The root manifest never depends on it.
import PackageDescription

let package = Package(
    name: "Dangerfile",
    platforms: [.macOS(.v26)],
    dependencies: [
        // `name:` keeps the identity the products are looked up by, whatever
        // the checkout's directory is called.
        .package(name: "swift-steward", path: ".."),
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

import Foundation

/// The executables the test build puts beside the tests, found as
/// SwiftStewardTests' `CommandLineTool` finds `steward`: `swift test` puts
/// the tests' resource bundle in the products directory, Xcode the
/// `.xctest` bundle.
enum BuiltExecutable {
    /// The executable `name`, or nil when the build didn't make it.
    static func url(named name: String) -> URL? {
        let directories = [Bundle.module.bundleURL.deletingLastPathComponent()] + Bundle.allBundles
            .filter { $0.bundleURL.pathExtension == "xctest" }
            .map { $0.bundleURL.deletingLastPathComponent() }
        return directories.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The executable `name`, throwing when the build didn't make it.
    static func required(_ name: String) throws -> URL {
        guard let url = url(named: name) else {
            throw FixtureError("the \(name) executable wasn't built beside the tests; run swift build --build-tests")
        }
        return url
    }
}

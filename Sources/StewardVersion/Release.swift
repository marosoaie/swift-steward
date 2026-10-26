/// The swift-steward release this build is.
package enum Release {
    /// `MAJOR.MINOR.PATCH`: what `steward --version` prints and what
    /// Steward's reports name. Changed only by the release procedure in
    /// AGENTS.md, whose workflow checks the built binary against it.
    package static let version = "2.0.0"
}

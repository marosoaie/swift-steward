/// One reviewed change to GitHub's OpenAPI description, with the evidence for it.
///
/// Fixes are data, decoded from `Specs/github/fixes.yaml`. Every edit checks
/// that upstream still needs it before it applies: once GitHub corrects a
/// discrepancy, regeneration fails and names the fix to drop, instead of
/// carrying a stale patch forever.
package struct SpecFix: Decodable, Equatable, Sendable {
    /// A short, unique identifier; failures name the fix by it.
    package let name: String
    /// What upstream gets wrong, or why the generator needs the change.
    package let why: String
    /// The recorded response in `Tests/GitHubAPITests/Fixtures` that decodes
    /// wrongly without the fix. Every edit that corrects upstream names one.
    package let fixture: String?
    /// The change itself.
    package let edit: Edit

    /// Creates a fix from its parts.
    package init(name: String, why: String, fixture: String? = nil, edit: Edit) {
        self.name = name
        self.why = why
        self.fixture = fixture
        self.edit = edit
    }
}

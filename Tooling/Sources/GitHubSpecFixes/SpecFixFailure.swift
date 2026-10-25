/// A fix that no longer applies, and why.
package struct SpecFixFailure: Error, Equatable, CustomStringConvertible {
    /// Why an edit refused to apply.
    package enum Reason: Error, Equatable {
        /// Upstream already says what the fix says: drop the fix.
        case redundant(String)
        /// The node the edit changes is gone (keys from the root): upstream
        /// moved or removed it, so the fix needs updating.
        case targetMissing(path: [String])
    }

    /// The fix's ``SpecFix/name``.
    package let fix: String
    /// Why it no longer applies.
    package let reason: Reason

    /// Creates a failure for the fix named `fix`.
    package init(fix: String, reason: Reason) {
        self.fix = fix
        self.reason = reason
    }

    /// The fix's name, what changed upstream, and what to do about it.
    package var description: String {
        switch reason {
        case let .redundant(change):
            "\(fix): \(change); drop the fix"
        case let .targetMissing(path):
            "\(fix): the description has no \(path.joined(separator: "/")); update the fix"
        }
    }
}

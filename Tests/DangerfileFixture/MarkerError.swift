import Foundation

/// What the "Fixture marker" rule throws.
struct MarkerError: LocalizedError {
    var errorDescription: String? { "the title asks this rule to throw" }
}

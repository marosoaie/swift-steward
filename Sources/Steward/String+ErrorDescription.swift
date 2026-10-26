import Foundation

extension String {
    /// What `error` says about itself, for a person: a `LocalizedError`'s
    /// description, Foundation's message for its own errors, a type's
    /// `description`, or else the error as Swift would debug-print it,
    /// which names its type.
    init(errorDescription error: any Error) {
        if let description = (error as? any LocalizedError)?.errorDescription {
            self = description
        } else if type(of: error) is NSError.Type {
            // Darwin only: every error converts to `NSError`, whose
            // `localizedDescription` for anything else is "The operation
            // couldn't be completed".
            self = error.localizedDescription
        } else if let convertible = error as Any as? any CustomStringConvertible {
            // Through `Any`: Darwin's compiler calls a direct cast from
            // `any Error` one that always succeeds, though it doesn't.
            self = convertible.description
        } else {
            self = String(reflecting: error)
        }
    }
}

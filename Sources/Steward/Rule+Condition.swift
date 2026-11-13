extension Rule {
    /// A group's condition, and what the log says when it doesn't hold.
    struct Condition: Sendable {
        var holds: @Sendable (Context) throws -> Bool
        var skipReason: String
    }
}

extension LocalRepository {
    /// Nil for every name: a reader that doesn't give its own knows no
    /// commit by name.
    public func commit(named name: String) async throws -> String? {
        nil
    }

    /// `.identity` when `built` is `head`; otherwise throws, since a reader
    /// that doesn't give its own has no line maps.
    public func lineMap(from built: String, to head: String, attributesFrom mergeBase: String) async throws -> LineMap {
        guard built == head else { throw MissingLineMap(built: built, head: head) }
        return .identity
    }
}

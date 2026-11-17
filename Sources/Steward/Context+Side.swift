extension Context {
    /// One end of the pull request's changes.
    ///
    /// Minor releases may add cases, so a `switch` over one needs an
    /// `@unknown default`.
    #if hasAttribute(nonexhaustive)
    @nonexhaustive
    #endif
    public enum Side: Sendable, Hashable {
        /// The merge base, `git.mergeBase`, where the changes start.
        case mergeBase
        /// The head commit, `git.head`, where they end.
        case head
    }

    /// The SHA of the commit at `side`.
    func commit(at side: Side) -> String {
        switch side {
        case .mergeBase: git.mergeBase
        case .head: git.head
        }
    }
}

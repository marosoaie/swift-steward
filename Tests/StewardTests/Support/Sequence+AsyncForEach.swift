extension Sequence {
    /// Runs `body` on each element in turn, waiting for each to finish.
    func asyncForEach(_ body: (Element) async throws -> Void) async rethrows {
        // Imperative: `forEach` takes no async closure.
        for element in self {
            try await body(element)
        }
    }
}

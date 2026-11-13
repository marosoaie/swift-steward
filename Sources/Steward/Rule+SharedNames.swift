extension [Rule] {
    /// The run's warning when rules share a name, which the log and the
    /// report tell rules apart by, or nil when each rule's name is its own.
    ///
    /// One warning lists every shared name, once each, in the order it
    /// first appears, since GitHub shows only a step's first ten warning
    /// annotations. Names are compared as `String`s are, so ones that
    /// differ only in case are different names.
    var sharedNamesWarning: String? {
        let counts = Dictionary(map { ($0.name, 1) }, uniquingKeysWith: +)
        let shared = map(\.name).reduce(into: [String]()) { shared, name in
            if counts[name, default: 0] > 1, !shared.contains(name) {
                shared.append(name)
            }
        }
        guard !shared.isEmpty else { return nil }
        let list = shared.map { "“\($0)” (\(counts[$0, default: 0]) rules)" }.joined(separator: ", ")
        return """
            Some rules share a name, so the log and the report can't tell their findings apart: \(list). \
            List each rule once, under its own name.
            """
    }
}

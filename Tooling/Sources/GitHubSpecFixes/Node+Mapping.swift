import Yams

// Keys match by text. Yams compares tags and styles too, so to it `'204'`,
// a plain `204` (an int) and `Node("204")` are three different keys, and a
// fix that looked keys up its way would miss upstream's own entry and append
// a duplicate.
extension Node {
    /// The value for the mapping key whose text is `key`, or nil when there's
    /// none or this isn't a mapping.
    package func value(forKey key: String) -> Node? {
        mapping?.first { $0.key.string == key }?.value
    }

    /// Replaces the value for `key` in place, appends it if absent, or
    /// removes it when `value` is nil. Non-mappings come back unchanged.
    package func setting(_ key: String, to value: Node?) -> Node {
        guard let mapping else {
            return self
        }
        let pairs = mapping.map { ($0.key, $0.value) }
        let updated: [(Node, Node)] = switch (pairs.firstIndex { $0.0.string == key }, value) {
        case let (index?, value?):
            pairs.enumerated().map { $0.offset == index ? ($0.element.0, value) : $0.element }
        case let (index?, nil):
            pairs.enumerated().filter { $0.offset != index }.map(\.element)
        case let (nil, value?):
            pairs + [(Node(key), value)]
        case (nil, nil):
            pairs
        }
        return .mapping(Node.Mapping(updated, mapping.tag, mapping.style))
    }

    /// Replaces the node at `path` (mapping keys from here) with what
    /// `transform` makes of it.
    func updating(
        at path: [String],
        _ transform: (Node) throws(SpecFixFailure.Reason) -> Node
    ) throws(SpecFixFailure.Reason) -> Node {
        try updating(at: path[...], from: [], transform)
    }

    private func updating(
        at path: ArraySlice<String>,
        from parent: [String],
        _ transform: (Node) throws(SpecFixFailure.Reason) -> Node
    ) throws(SpecFixFailure.Reason) -> Node {
        guard let key = path.first else {
            return try transform(self)
        }
        guard let child = value(forKey: key) else {
            throw .targetMissing(path: parent + [key])
        }
        return setting(key, to: try child.updating(at: path.dropFirst(), from: parent + [key], transform))
    }
}

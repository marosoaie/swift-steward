import Yams

/// One reviewed change to GitHub's description, with the evidence for it.
///
/// Every edit checks that upstream is still wrong before it applies: once
/// GitHub fixes a discrepancy, regeneration fails and names the fix to drop,
/// instead of carrying a stale patch forever.
struct SpecFix {
    /// What upstream gets wrong, and the recorded fixture that shows it.
    let why: String
    let edit: Edit

    enum Edit {
        /// Adds `'null'` to the `type` of a property of the schema at
        /// `schema`. The generator's `filter` writes OpenAPI 3.1, where
        /// `nullable: true` no longer exists.
        case makeNullable(schema: [String], property: String)
        /// Removes a property from the `required` list of the schema at `schema`.
        case makeOptional(schema: [String], property: String)
        /// Adds a value to the string enum of a property.
        case addEnumValue(schema: [String], property: String, value: String)
        /// Removes `deprecated: true` from a property.
        case undeprecate(schema: [String], property: String)
        /// Removes the node at `path`.
        case remove(path: [String])
        /// Declares a response an operation returns but doesn't list, as a
        /// reference to a shared response in `components/responses`.
        case addResponse(path: String, method: String, status: String, response: String)
    }

    /// The key path of a component schema.
    static func component(_ name: String, _ nested: String...) -> [String] {
        ["components", "schemas", name] + nested.flatMap { ["properties", $0] }
    }

    func applied(to document: Node) throws -> Node {
        switch edit {
        case let .makeNullable(schema, property):
            try document.updating(at: schema + ["properties", property, "type"]) { node in
                let types = node.sequence.map(Array.init) ?? [node]
                guard !types.contains(where: { $0.string == "null" }) else {
                    throw stale("upstream already makes \(property) nullable")
                }
                return Node(types + [Node("null", Tag(.str), .singleQuoted)])
            }
        case let .makeOptional(schema, property):
            try document.updating(at: schema + ["required"]) { node in
                let required = node.sequence.map(Array.init) ?? []
                guard required.contains(where: { $0.string == property }) else {
                    throw stale("upstream no longer requires \(property)")
                }
                return Node(required.filter { $0.string != property })
            }
        case let .addEnumValue(schema, property, value):
            try document.updating(at: schema + ["properties", property, "enum"]) { node in
                let values = node.sequence.map(Array.init) ?? []
                guard !values.contains(where: { $0.string == value }) else {
                    throw stale("upstream already lists \(value)")
                }
                return Node(values + [Node(value)])
            }
        case let .undeprecate(schema, property):
            try document.updating(at: schema + ["properties", property]) { node in
                guard node.value(forKey: "deprecated")?.bool == true else {
                    throw stale("upstream no longer deprecates \(property)")
                }
                return node.setting("deprecated", to: nil)
            }
        case let .remove(path):
            try document.updating(at: Array(path.dropLast())) { node in
                guard let key = path.last, node.value(forKey: key) != nil else {
                    throw stale("upstream no longer has \(path.joined(separator: "/"))")
                }
                return node.setting(key, to: nil)
            }
        case let .addResponse(path, method, status, response):
            try document.updating(at: ["paths", path, method, "responses"]) { node in
                guard node.value(forKey: status) == nil else {
                    throw stale("upstream already declares \(status) for \(method) \(path)")
                }
                return node.setting(status, to: ["$ref": Node("#/components/responses/\(response)")])
            }
        }
    }

    private func stale(_ reason: String) -> SpecFixError {
        SpecFixError(message: "\(reason); drop the fix: \(why)")
    }
}

struct SpecFixError: Error, CustomStringConvertible {
    let description: String

    init(message: String) {
        description = message
    }
}

// Keys match by text. Yams compares tags and styles too, so to it `'204'`,
// a plain `204` (an int) and `Node("204")` are three different keys, and a
// fix that looked keys up its way would miss upstream's own entry.
extension Node {
    func value(forKey key: String) -> Node? {
        mapping?.first { $0.key.string == key }?.value
    }

    /// Replaces the value for `key` in place, appends it if absent, or
    /// removes it when `value` is nil. Non-mappings come back unchanged.
    func setting(_ key: String, to value: Node?) -> Node {
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

    /// Replaces the node at `path` (mapping keys from here) with `transform`'s result.
    func updating(at path: [String], _ transform: (Node) throws -> Node) throws -> Node {
        guard let key = path.first else {
            return try transform(self)
        }
        guard let child = value(forKey: key) else {
            throw SpecFixError(message: "no \(key) in the description at \(path.joined(separator: "/"))")
        }
        return setting(key, to: try child.updating(at: Array(path.dropFirst()), transform))
    }
}

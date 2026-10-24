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
        /// Adds `nullable: true` to a property of the schema at `schema`.
        case makeNullable(schema: [String], property: String)
        /// Removes a property from the `required` list of the schema at `schema`.
        case makeOptional(schema: [String], property: String)
        /// Adds a value to the string enum of a property.
        case addEnumValue(schema: [String], property: String, value: String)
        /// Removes `deprecated: true` from a property.
        case undeprecate(schema: [String], property: String)
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
            try document.updating(at: schema + ["properties", property]) { node in
                guard node.mapping?["nullable"]?.bool != true else {
                    throw SpecFixError(message: "upstream already marks \(property) nullable; drop: \(why)")
                }
                return node.setting("nullable", to: Node("true", Tag(.bool)))
            }
        case let .makeOptional(schema, property):
            try document.updating(at: schema + ["required"]) { node in
                let required = node.sequence.map(Array.init) ?? []
                guard required.contains(Node(property)) else {
                    throw SpecFixError(message: "upstream no longer requires \(property); drop: \(why)")
                }
                return Node(required.filter { $0 != Node(property) })
            }
        case let .addEnumValue(schema, property, value):
            try document.updating(at: schema + ["properties", property, "enum"]) { node in
                let values = node.sequence.map(Array.init) ?? []
                guard !values.contains(Node(value)) else {
                    throw SpecFixError(message: "upstream already lists \(value); drop: \(why)")
                }
                return Node(values + [Node(value)])
            }
        case let .undeprecate(schema, property):
            try document.updating(at: schema + ["properties", property]) { node in
                guard var mapping = node.mapping, mapping["deprecated"]?.bool == true else {
                    throw SpecFixError(message: "upstream no longer deprecates \(property); drop: \(why)")
                }
                mapping["deprecated"] = nil
                return .mapping(mapping)
            }
        case let .addResponse(path, method, status, response):
            try document.updating(at: ["paths", path, method, "responses"]) { node in
                guard node.mapping?[status] == nil else {
                    throw SpecFixError(message: "upstream already declares \(status) for \(method) \(path); drop: \(why)")
                }
                return node.setting(status, to: ["$ref": Node("#/components/responses/\(response)")])
            }
        }
    }
}

struct SpecFixError: Error, CustomStringConvertible {
    let description: String

    init(message: String) {
        description = message
    }
}

extension Node {
    /// Replaces the node at `path` (mapping keys from here) with `transform`'s result.
    func updating(at path: [String], _ transform: (Node) throws -> Node) throws -> Node {
        guard let key = path.first else {
            return try transform(self)
        }
        guard var mapping = self.mapping, let child = mapping[key] else {
            throw SpecFixError(message: "no \(key) in the description at this path: \(path.joined(separator: "/"))")
        }
        mapping[key] = try child.updating(at: Array(path.dropFirst()), transform)
        return .mapping(mapping)
    }

    func setting(_ key: String, to value: Node) -> Node {
        guard var mapping = self.mapping else {
            return self
        }
        mapping[key] = value
        return .mapping(mapping)
    }
}

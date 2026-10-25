import Yams

extension SpecFix {
    /// Applies the fix to `document`.
    ///
    /// - Throws: A failure naming the fix when upstream already says what the
    ///   fix says, or when the node it edits no longer exists.
    package func applied(to document: Node) throws(SpecFixFailure) -> Node {
        do {
            return try edit.applied(to: document)
        } catch {
            throw SpecFixFailure(fix: name, reason: error)
        }
    }
}

extension SpecFix.Edit {
    private typealias Refusal = SpecFixFailure.Reason

    func applied(to document: Node) throws(SpecFixFailure.Reason) -> Node {
        try document.updating(at: target) { node throws(Refusal) in
            try transformed(node)
        }
    }

    /// The keys from the root to the node the edit replaces.
    private var target: [String] {
        switch self {
        case let .makeNullable(schema, property):
            Self.path(of: schema) + ["properties", property, "type"]
        case let .makeOptional(schema, _):
            Self.path(of: schema) + ["required"]
        case let .addEnumValue(schema, property, _):
            Self.path(of: schema) + ["properties", property, "enum"]
        case let .undeprecate(schema, property):
            Self.path(of: schema) + ["properties", property]
        case let .remove(path):
            Array(path.dropLast())
        case let .addResponse(path, method, _, _):
            ["paths", path, method, "responses"]
        }
    }

    private func transformed(_ node: Node) throws(Refusal) -> Node {
        switch self {
        case let .makeNullable(_, property):
            try Self.addingNull(to: node, of: property)
        case let .makeOptional(_, property):
            try Self.removing(property, fromRequired: node)
        case let .addEnumValue(_, property, value):
            try Self.adding(value, toEnumOf: property, in: node)
        case let .undeprecate(_, property):
            try Self.undeprecating(property, in: node)
        case let .remove(path):
            try Self.removing(childAt: path, from: node)
        case let .addResponse(path, method, status, response):
            try Self.declaring(status, as: response, for: "\(method) \(path)", in: node)
        }
    }

    private static func path(of schema: [String]) -> [String] {
        ["components", "schemas"] + schema.prefix(1) + schema.dropFirst().flatMap { ["properties", $0] }
    }

    private static func addingNull(to type: Node, of property: String) throws(Refusal) -> Node {
        let types = type.sequence.map(Array.init) ?? [type]
        guard !types.contains(where: { $0.string == "null" }) else {
            throw .redundant("upstream already makes \(property) nullable")
        }
        return Node(types + [Node("null", Tag(.str), .singleQuoted)])
    }

    private static func removing(_ property: String, fromRequired required: Node) throws(Refusal) -> Node {
        let names = required.sequence.map(Array.init) ?? []
        guard names.contains(where: { $0.string == property }) else {
            throw .redundant("upstream no longer requires \(property)")
        }
        return Node(names.filter { $0.string != property })
    }

    private static func adding(_ value: String, toEnumOf property: String, in values: Node) throws(Refusal) -> Node {
        let listed = values.sequence.map(Array.init) ?? []
        guard !listed.contains(where: { $0.string == value }) else {
            throw .redundant("upstream already lists \(value) for \(property)")
        }
        return Node(listed + [Node(value, Tag(.str), .singleQuoted)])
    }

    private static func undeprecating(_ name: String, in property: Node) throws(Refusal) -> Node {
        guard property.value(forKey: "deprecated")?.bool == true else {
            throw .redundant("upstream no longer deprecates \(name)")
        }
        return property.setting("deprecated", to: nil)
    }

    private static func removing(childAt path: [String], from parent: Node) throws(Refusal) -> Node {
        guard let key = path.last, parent.value(forKey: key) != nil else {
            throw .redundant("upstream no longer has \(path.joined(separator: "/"))")
        }
        return parent.setting(key, to: nil)
    }

    private static func declaring(
        _ status: String,
        as response: String,
        for operation: String,
        in responses: Node
    ) throws(Refusal) -> Node {
        guard responses.value(forKey: status) == nil else {
            throw .redundant("upstream already declares \(status) for \(operation)")
        }
        return responses.setting(status, to: ["$ref": Node("#/components/responses/\(response)")])
    }
}

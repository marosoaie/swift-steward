import Yams

/// The reviewed fixes for a description, in the order they apply
/// (`Specs/github/fixes.yaml`).
package struct SpecFixList: Equatable, Sendable {
    /// Why a fix list can't be used.
    package enum Problem: Error, Equatable, CustomStringConvertible {
        /// An entry breaks a rule of the format; the message names it.
        case invalid(String)
        /// Fixes that no longer apply, all of them, so one regeneration
        /// reports everything upstream has changed.
        case stale([SpecFixFailure])

        /// What's wrong, naming every fix involved.
        package var description: String {
            switch self {
            case let .invalid(message):
                "invalid fix list: \(message)"
            case let .stale(failures):
                """
                \(failures.count == 1
                    ? "1 spec fix no longer applies; update or drop it"
                    : "\(failures.count) spec fixes no longer apply; update or drop them") \
                in Specs/github/fixes.yaml:
                \(failures.map { "  \($0)" }.joined(separator: "\n"))
                """
            }
        }
    }

    /// The fixes, in order.
    package let fixes: [SpecFix]

    /// Wraps `fixes` after checking that each has a unique name, says why,
    /// addresses something, and names a fixture if it corrects upstream.
    package init(_ fixes: [SpecFix]) throws(Problem) {
        let names = fixes.map(\.name)
        if let duplicate = names.enumerated().first(where: { names[..<$0.offset].contains($0.element) }) {
            throw .invalid("two fixes are named \(duplicate.element)")
        }
        if let fix = fixes.first(where: { $0.name.isEmpty || $0.why.isEmpty }) {
            throw .invalid("every fix needs a name and a why (\(fix.name.isEmpty ? "unnamed fix" : fix.name))")
        }
        if let fix = fixes.first(where: { $0.edit.correctsUpstream && ($0.fixture ?? "").isEmpty }) {
            throw .invalid("\(fix.name) corrects upstream but names no fixture that shows the discrepancy")
        }
        if let fix = fixes.first(where: { !$0.edit.hasTarget }) {
            throw .invalid("\(fix.name) has an empty schema or path")
        }
        self.fixes = fixes
    }

    /// Decodes a fix list from YAML: a sequence of ``SpecFix`` mappings.
    package init(yaml: String) throws {
        try self.init(YAMLDecoder().decode([SpecFix].self, from: yaml))
    }

    /// Applies every fix in order.
    ///
    /// - Throws: ``Problem/stale(_:)`` listing every fix that no longer
    ///   applies; a stale fix doesn't stop the ones after it from being checked.
    package func applied(to document: Node) throws(Problem) -> Node {
        let (fixed, failures) = fixes.reduce(into: (document, [SpecFixFailure]())) { state, fix in
            do throws(SpecFixFailure) {
                state.0 = try fix.applied(to: state.0)
            } catch {
                state.1.append(error)
            }
        }
        guard failures.isEmpty else {
            throw .stale(failures)
        }
        return fixed
    }
}

private extension SpecFix.Edit {
    var hasTarget: Bool {
        switch self {
        case let .makeNullable(schema, _), let .makeOptional(schema, _),
             let .addEnumValue(schema, _, _), let .undeprecate(schema, _):
            !schema.isEmpty
        case let .remove(path):
            !path.isEmpty
        case let .addResponse(path, _, _, _):
            !path.isEmpty
        }
    }
}

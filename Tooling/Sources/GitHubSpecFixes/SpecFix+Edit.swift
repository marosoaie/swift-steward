extension SpecFix {
    /// One change to the description, addressed by intent rather than by
    /// position, so upstream reordering a list can't misdirect it.
    ///
    /// In YAML, an edit is a one-key mapping: the case name, then its labeled
    /// values (`addResponse: {path: …, method: patch, status: '404', …}`).
    /// A `schema` is a component schema name followed by the names of any
    /// nested properties: `[pull-request, head]` is
    /// `components/schemas/pull-request/properties/head`.
    package enum Edit: Decodable, Equatable, Sendable {
        /// Adds `'null'` to the `type` of a property. The generator's `filter`
        /// writes OpenAPI 3.1, where `nullable: true` no longer exists.
        case makeNullable(schema: [String], property: String)
        /// Removes a property from its schema's `required` list.
        case makeOptional(schema: [String], property: String)
        /// Adds a value to the `enum` of a property.
        case addEnumValue(schema: [String], property: String, value: String)
        /// Removes `deprecated: true` from a property.
        case undeprecate(schema: [String], property: String)
        /// Removes the node at `path`, a list of mapping keys from the root.
        case remove(path: [String])
        /// Declares a response an operation returns but doesn't list, as a
        /// reference to a shared response in `components/responses`.
        case addResponse(path: String, method: String, status: String, response: String)

        /// Whether the edit corrects what the description says GitHub does, as
        /// opposed to adapting the description for the generator. Corrections
        /// need a recorded response as evidence.
        package var correctsUpstream: Bool {
            switch self {
            case .makeNullable, .makeOptional, .addEnumValue, .addResponse:
                true
            case .undeprecate, .remove:
                false
            }
        }
    }
}

import GitHubSpecFixes
import Testing
import Yams

@Suite("Spec fixes apply only while upstream still needs them")
struct SpecFixTests {
    // '204' is quoted the way `filter` writes status codes, and `deprecated`
    // is a plain bool, so lookups have to go by text, not by Yams equality.
    let document = """
        paths:
          /items/{id}:
            delete:
              responses:
                '204':
                  description: Response
        components:
          schemas:
            item:
              required: [id, name]
              properties:
                id: {type: integer}
                name: {type: string}
                tags: {type: [array, 'null']}
                state: {type: string, enum: [open, closed]}
                legacy: {type: boolean, deprecated: true}
                owner:
                  type: object
                  required: [login]
                  properties:
                    login: {type: string}
        x-webhooks: {}
        """

    func apply(_ edit: SpecFix.Edit) throws -> Node {
        try SpecFix(name: "test-fix", why: "test", edit: edit)
            .applied(to: try #require(try Yams.compose(yaml: document)))
    }

    func failure(_ edit: SpecFix.Edit) throws -> SpecFixFailure.Reason? {
        let document = try #require(try Yams.compose(yaml: document))
        do {
            _ = try SpecFix(name: "test-fix", why: "test", edit: edit).applied(to: document)
            return nil
        } catch {
            #expect(error.fix == "test-fix")
            return error.reason
        }
    }

    func item(_ node: Node) -> Node? {
        node.value(forKey: "components")?.value(forKey: "schemas")?.value(forKey: "item")
    }

    func property(_ name: String, of node: Node) -> Node? {
        item(node)?.value(forKey: "properties")?.value(forKey: name)
    }

    @Test("makeNullable adds null to a scalar type, and refuses a property that's already nullable")
    func makeNullable() throws {
        let fixed = try apply(.makeNullable(schema: ["item"], property: "name"))
        let types = property("name", of: fixed)?.value(forKey: "type")?.sequence?.compactMap(\.string)
        #expect(types == ["string", "null"])
        let reason = try failure(.makeNullable(schema: ["item"], property: "tags"))
        #expect(reason == .redundant("upstream already makes tags nullable"))
    }

    @Test("makeOptional drops a required property, and refuses an optional one")
    func makeOptional() throws {
        let fixed = try apply(.makeOptional(schema: ["item"], property: "name"))
        #expect(item(fixed)?.value(forKey: "required")?.sequence?.compactMap(\.string) == ["id"])
        #expect(try failure(.makeOptional(schema: ["item"], property: "tags")) != nil)
    }

    @Test("a schema path descends into nested properties")
    func nestedSchema() throws {
        let fixed = try apply(.makeOptional(schema: ["item", "owner"], property: "login"))
        let owner = property("owner", of: fixed)
        #expect(owner?.value(forKey: "required")?.sequence?.isEmpty == true)
        #expect(owner?.value(forKey: "type")?.string == "object")
    }

    @Test("addEnumValue appends a value, and refuses a listed one")
    func addEnumValue() throws {
        let fixed = try apply(.addEnumValue(schema: ["item"], property: "state", value: "merged"))
        let values = property("state", of: fixed)?.value(forKey: "enum")?.sequence?.compactMap(\.string)
        #expect(values == ["open", "closed", "merged"])
        #expect(try failure(.addEnumValue(schema: ["item"], property: "state", value: "open")) != nil)
    }

    @Test("undeprecate removes the marker, and refuses a property without one")
    func undeprecate() throws {
        let fixed = try apply(.undeprecate(schema: ["item"], property: "legacy"))
        #expect(property("legacy", of: fixed)?.value(forKey: "deprecated") == nil)
        #expect(property("legacy", of: fixed)?.value(forKey: "type")?.string == "boolean")
        #expect(try failure(.undeprecate(schema: ["item"], property: "name")) != nil)
    }

    @Test("remove drops a node, and refuses a missing one")
    func remove() throws {
        #expect(try apply(.remove(path: ["x-webhooks"])).value(forKey: "x-webhooks") == nil)
        #expect(try failure(.remove(path: ["x-nothing"])) == .redundant("upstream no longer has x-nothing"))
    }

    @Test("addResponse declares a shared response, and refuses a status upstream declares, quoted or not")
    func addResponse() throws {
        let fixed = try apply(.addResponse(path: "/items/{id}", method: "delete", status: "404", response: "not_found"))
        let responses = fixed.value(forKey: "paths")?.value(forKey: "/items/{id}")?
            .value(forKey: "delete")?.value(forKey: "responses")
        #expect(responses?.value(forKey: "404")?.value(forKey: "$ref")?.string == "#/components/responses/not_found")
        #expect(responses?.mapping?.count == 2)
        let reason = try failure(.addResponse(path: "/items/{id}", method: "delete", status: "204", response: "x"))
        #expect(reason == .redundant("upstream already declares 204 for delete /items/{id}"))
    }

    @Test("an edit whose target is gone fails and names the first missing key", arguments: [
        (SpecFix.Edit.makeOptional(schema: ["gone"], property: "id"), ["components", "schemas", "gone"]),
        (
            .makeNullable(schema: ["item"], property: "missing"),
            ["components", "schemas", "item", "properties", "missing"]
        ),
        (.addResponse(path: "/other", method: "get", status: "404", response: "x"), ["paths", "/other"]),
        (.remove(path: ["components", "responses", "x"]), ["components", "responses"]),
    ])
    func targetMissing(edit: SpecFix.Edit, path: [String]) throws {
        #expect(try failure(edit) == .targetMissing(path: path))
    }

    @Test("an edit leaves everything else in the document as it was")
    func untouched() throws {
        let original = try #require(try Yams.compose(yaml: document))
        let fixed = try apply(.remove(path: ["x-webhooks"]))
        #expect(fixed.value(forKey: "paths") == original.value(forKey: "paths"))
        #expect(fixed.value(forKey: "components") == original.value(forKey: "components"))
        #expect(try Yams.serialize(node: fixed).contains("'204':"))
    }

    @Test("a failure names the fix and says whether to drop or update it")
    func failureDescription() {
        #expect(
            SpecFixFailure(fix: "a-fix", reason: .redundant("upstream already lists x")).description
                == "a-fix: upstream already lists x; drop the fix"
        )
        #expect(
            SpecFixFailure(fix: "a-fix", reason: .targetMissing(path: ["paths", "/x"])).description
                == "a-fix: the description has no paths//x; update the fix"
        )
    }
}

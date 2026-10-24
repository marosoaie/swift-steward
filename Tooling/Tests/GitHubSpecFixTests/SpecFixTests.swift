@testable import github_spec_fix
import Testing
import Yams

@Suite("Spec fixes apply only while upstream is still wrong")
struct SpecFixTests {
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
        x-webhooks: {}
        """

    func apply(_ edit: SpecFix.Edit) throws -> Node {
        try SpecFix(why: "test", edit: edit).applied(to: try #require(try Yams.compose(yaml: document)))
    }

    func item(_ node: Node) -> Node? {
        node["components"]?["schemas"]?["item"]
    }

    @Test("makeNullable turns a scalar type into a type list with null, and refuses a nullable one")
    func makeNullable() throws {
        let fixed = try apply(.makeNullable(schema: SpecFix.component("item"), property: "name"))
        #expect(item(fixed)?["properties"]?["name"]?["type"]?.sequence?.compactMap(\.string) == ["string", "null"])
        #expect(throws: SpecFixError.self) {
            try apply(.makeNullable(schema: SpecFix.component("item"), property: "tags"))
        }
    }

    @Test("makeOptional drops a required property, and refuses an optional one")
    func makeOptional() throws {
        let fixed = try apply(.makeOptional(schema: SpecFix.component("item"), property: "name"))
        #expect(item(fixed)?["required"]?.sequence?.compactMap(\.string) == ["id"])
        #expect(throws: SpecFixError.self) {
            try apply(.makeOptional(schema: SpecFix.component("item"), property: "tags"))
        }
    }

    @Test("addEnumValue appends a value, and refuses a listed one")
    func addEnumValue() throws {
        let fixed = try apply(.addEnumValue(schema: SpecFix.component("item"), property: "state", value: "merged"))
        #expect(item(fixed)?["properties"]?["state"]?["enum"]?.sequence?.count == 3)
        #expect(throws: SpecFixError.self) {
            try apply(.addEnumValue(schema: SpecFix.component("item"), property: "state", value: "open"))
        }
    }

    @Test("undeprecate removes the marker, and refuses a property without one")
    func undeprecate() throws {
        let fixed = try apply(.undeprecate(schema: SpecFix.component("item"), property: "legacy"))
        #expect(item(fixed)?["properties"]?["legacy"]?["deprecated"] == nil)
        #expect(throws: SpecFixError.self) {
            try apply(.undeprecate(schema: SpecFix.component("item"), property: "name"))
        }
    }

    @Test("remove drops a node, and refuses a missing one")
    func remove() throws {
        #expect(try apply(.remove(path: ["x-webhooks"]))["x-webhooks"] == nil)
        #expect(throws: SpecFixError.self) {
            try apply(.remove(path: ["x-nothing"]))
        }
    }

    @Test("addResponse declares a shared response, and refuses a declared status")
    func addResponse() throws {
        let fixed = try apply(.addResponse(path: "/items/{id}", method: "delete", status: "404", response: "not_found"))
        let responses = fixed["paths"]?["/items/{id}"]?["delete"]?["responses"]
        #expect(responses?["404"]?["$ref"]?.string == "#/components/responses/not_found")
        #expect(throws: SpecFixError.self) {
            try apply(.addResponse(path: "/items/{id}", method: "delete", status: "204", response: "not_found"))
        }
    }

    @Test("an edit whose path no longer exists fails instead of silently doing nothing")
    func missingPath() {
        #expect(throws: SpecFixError.self) {
            try apply(.makeOptional(schema: SpecFix.component("gone"), property: "id"))
        }
    }
}

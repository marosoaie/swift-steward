import GitHubSpecFixes
import Testing
import Yams

@Suite("A fix list decodes from YAML, validates its entries, and reports every stale fix")
struct SpecFixListTests {
    @Test("every kind of edit decodes from its one-key mapping")
    func decodesEveryEdit() throws {
        let list = try SpecFixList(yaml: """
            - name: nullable
              why: w
              fixture: f.http
              edit: {makeNullable: {schema: [pull-request, head], property: repo}}
            - name: optional
              why: w
              fixture: f.http
              edit: {makeOptional: {schema: [issue-comment], property: user}}
            - name: enum
              why: w
              fixture: f.http
              edit: {addEnumValue: {schema: [pull-request], property: state, value: merged}}
            - name: deprecation
              why: w
              edit: {undeprecate: {schema: [repository], property: has_downloads}}
            - name: removal
              why: w
              edit: {remove: {path: [x-webhooks]}}
            - name: response
              why: w
              fixture: f.http
              edit:
                addResponse:
                  path: /repos/{owner}/{repo}/issues/comments/{comment_id}
                  method: patch
                  status: '404'
                  response: not_found
            """)
        #expect(list.fixes.map(\.edit) == [
            .makeNullable(schema: ["pull-request", "head"], property: "repo"),
            .makeOptional(schema: ["issue-comment"], property: "user"),
            .addEnumValue(schema: ["pull-request"], property: "state", value: "merged"),
            .undeprecate(schema: ["repository"], property: "has_downloads"),
            .remove(path: ["x-webhooks"]),
            .addResponse(
                path: "/repos/{owner}/{repo}/issues/comments/{comment_id}",
                method: "patch",
                status: "404",
                response: "not_found"
            ),
        ])
        #expect(list.fixes.map(\.fixture) == ["f.http", "f.http", "f.http", nil, nil, "f.http"])
    }

    @Test("an unknown kind of edit or a missing field fails to decode", arguments: [
        "- {name: a, why: w, edit: {rename: {path: [x]}}}",
        "- {name: a, why: w, edit: {remove: {}}}",
        "- {name: a, edit: {remove: {path: [x]}}}",
    ])
    func rejectsMalformedEntries(yaml: String) {
        #expect(throws: (any Error).self) {
            try SpecFixList(yaml: yaml)
        }
    }

    @Test("the list's rules reject an entry that breaks them", arguments: [
        (
            [.removal(named: "a"), .removal(named: "a")],
            "two fixes are named a"
        ),
        (
            [SpecFix(name: "a", why: "", edit: .remove(path: ["x"]))],
            "every fix needs a name and a why (a)"
        ),
        (
            [SpecFix(name: "a", why: "w", edit: .addResponse(path: "/x", method: "get", status: "404", response: "r"))],
            "a corrects upstream but names no fixture that shows the discrepancy"
        ),
        (
            [SpecFix(name: "a", why: "w", fixture: "", edit: .makeOptional(schema: ["s"], property: "p"))],
            "a corrects upstream but names no fixture that shows the discrepancy"
        ),
        (
            [SpecFix(name: "a", why: "w", fixture: "f", edit: .makeNullable(schema: [], property: "p"))],
            "a has an empty schema or path"
        ),
        (
            [SpecFix(name: "a", why: "w", edit: .remove(path: []))],
            "a has an empty schema or path"
        ),
    ])
    func rejectsInvalidLists(fixes: [SpecFix], message: String) {
        #expect(throws: SpecFixList.Problem.invalid(message)) {
            try SpecFixList(fixes)
        }
    }

    @Test("a single stale fix is reported in the singular")
    func reportsOneStaleFix() {
        let problem = SpecFixList.Problem.stale([SpecFixFailure(fix: "only", reason: .redundant("upstream has it"))])
        #expect(problem.description == """
            1 spec fix no longer applies; update or drop it in Specs/github/fixes.yaml:
              only: upstream has it; drop the fix
            """)
    }

    @Test("fixes apply in order, each seeing the previous one's result")
    func appliesInOrder() throws {
        let list = try SpecFixList([
            SpecFix(name: "add", why: "w", fixture: "f", edit: .addEnumValue(schema: ["s"], property: "p", value: "c")),
            SpecFix(name: "drop", why: "w", edit: .remove(path: ["components", "schemas", "s", "properties", "p"])),
        ])
        let yaml = "components: {schemas: {s: {properties: {p: {enum: [a]}}}}}"
        let document = try #require(try Yams.compose(yaml: yaml))
        let fixed = try list.applied(to: document)
        let properties = fixed.value(forKey: "components")?.value(forKey: "schemas")?
            .value(forKey: "s")?.value(forKey: "properties")
        #expect(properties?.mapping?.isEmpty == true)
    }

    @Test("every stale fix is reported, not just the first, and fixes that still apply don't hide them")
    func reportsEveryStaleFix() throws {
        let list = try SpecFixList([
            SpecFix(name: "first", why: "w", edit: .remove(path: ["gone"])),
            SpecFix(name: "fine", why: "w", edit: .remove(path: ["kept"])),
            SpecFix(name: "third", why: "w", edit: .undeprecate(schema: ["s"], property: "p")),
        ])
        let document = try #require(try Yams.compose(yaml: "kept: 1\ncomponents: {schemas: {}}"))
        let problem = #expect(throws: SpecFixList.Problem.self) {
            try list.applied(to: document)
        }
        #expect(problem == .stale([
            SpecFixFailure(fix: "first", reason: .redundant("upstream no longer has gone")),
            SpecFixFailure(fix: "third", reason: .targetMissing(path: ["components", "schemas", "s"])),
        ]))
        #expect(problem?.description == """
            2 spec fixes no longer apply; update or drop them in Specs/github/fixes.yaml:
              first: upstream no longer has gone; drop the fix
              third: the description has no components/schemas/s; update the fix
            """)
    }
}

private extension SpecFix {
    static func removal(named name: String) -> SpecFix {
        SpecFix(name: name, why: "w", edit: .remove(path: ["x"]))
    }
}

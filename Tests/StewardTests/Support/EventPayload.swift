import Foundation

/// A `pull_request` event payload as JSON, to rewrite before a run reads it.
struct EventPayload {
    var object: [String: Any]

    /// A payload Actions wrote, from the Fixtures folder: `name` is
    /// `pull-request-event.opened` or `pull-request-event.synchronize`, both
    /// recorded on swift-steward#21.
    static func recorded(_ name: String) throws -> EventPayload {
        try EventPayload(object: json(named: name, in: "Fixtures"))
    }

    /// A payload built around what `pulls/get` answered for a pull request,
    /// from the Fixtures/pulls folder: `name` is `<repository>-<number>`.
    static func pullRequest(_ name: String, action: String = "synchronize") throws -> EventPayload {
        try EventPayload(object: ["action": action, "pull_request": json(named: name, in: "Fixtures/pulls")])
    }

    private static func json(named name: String, in folder: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: folder) else {
            throw FixtureError("no fixture \(folder)/\(name).json")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw FixtureError("\(folder)/\(name).json isn't a JSON object")
        }
        return object
    }

    /// The payload with its action, or its pull request's base or head
    /// commit, replaced.
    func setting(action: String? = nil, base: String? = nil, head: String? = nil) -> EventPayload {
        var payload = self
        var pullRequest = object["pull_request"] as? [String: Any] ?? [:]
        func set(_ sha: String?, on branch: String) {
            guard let sha else { return }
            var fields = pullRequest[branch] as? [String: Any] ?? [:]
            fields["sha"] = sha
            pullRequest[branch] = fields
        }
        set(base, on: "base")
        set(head, on: "head")
        payload.object["pull_request"] = pullRequest
        if let action {
            payload.object["action"] = action
        }
        return payload
    }

    /// The pull request's field `key`, such as `merge_commit_sha`.
    func pullRequestField(_ key: String) -> Any? {
        (object["pull_request"] as? [String: Any])?[key]
    }

    func write(to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}

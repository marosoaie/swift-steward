import Foundation
@testable import Steward
import Testing

@Suite("The events and environments a context refuses")
struct ContextEventTests {
    @Test("a URL variable that isn't an http(s) URL is refused", arguments: [
        "ghe.example.com", "ftp://ghe.example.com", "https://", "https://ghe example.com",
    ])
    func invalidURL(value: String) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        environment["GITHUB_SERVER_URL"] = value
        await #expect(throws: ContextError.invalidURL(variable: "GITHUB_SERVER_URL", value: value)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("every activity type Steward runs on builds a context", arguments: [
        "opened", "synchronize", "reopened", "edited", "ready_for_review",
    ])
    func supportedAction(action: String) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let environment = try repository.actionsEnvironment(action: action, base: commit, head: commit)
        let context = try await Context.actions(environment: environment)
        #expect(context.git.head == commit)
    }

    @Test("any other activity type is refused", arguments: [
        "closed", "labeled", "converted_to_draft", "review_requested",
    ])
    func unsupportedAction(action: String) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let environment = try repository.actionsEnvironment(action: action, base: commit, head: commit)
        await #expect(throws: ContextError.unsupportedAction(action)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("the refusal of an activity type names every one Steward runs on")
    func unsupportedActionMessage() {
        let description = ContextError.unsupportedAction("labeled").description
        // With the space, so "reopened" can't stand in for "opened".
        let missing = Context.supportedActions.filter { !description.contains(" \($0)") }
        #expect(missing.isEmpty, "\(description)")
    }

    @Test("any event but pull_request is refused", arguments: [
        "pull_request_target", "push", "workflow_dispatch", "merge_group",
    ])
    func unsupportedEvent(name: String) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        environment["GITHUB_EVENT_NAME"] = name
        await #expect(throws: ContextError.unsupportedEvent(name)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("a variable Actions always sets is required, and empty counts as unset", arguments: [
        "GITHUB_EVENT_NAME", "GITHUB_EVENT_PATH", "GITHUB_WORKSPACE", "GITHUB_SHA",
    ], [nil, ""])
    func missingVariable(name: String, value: String?) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        environment[name] = value
        await #expect(throws: ContextError.missingEnvironmentVariable(name)) {
            try await Context.actions(environment: environment)
        }
    }

    @Test("an event payload that can't be read is reported with its path")
    func unreadablePayload() async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        var environment = try repository.actionsEnvironment(base: commit, head: commit)
        let missing = repository.root.appendingPathComponent("missing.json").path
        environment["GITHUB_EVENT_PATH"] = missing
        let error = await #expect(throws: ContextError.self) {
            try await Context.actions(environment: environment)
        }
        guard case .unreadableEventPayload(let path, _) = error else {
            Issue.record("expected unreadableEventPayload, got \(String(describing: error))")
            return
        }
        #expect(path == missing)
    }

    @Test("an event payload that isn't a pull request event's says what's wrong", arguments: [
        "not JSON", "no pull request", "no base SHA", "number as text",
    ])
    func malformedPayload(damage: String) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let environment = try repository.actionsEnvironment(base: commit, head: commit)
        var payload = try EventPayload.recorded("pull-request-event.opened")
        var pullRequest = try #require(payload.object["pull_request"] as? [String: Any])
        let reason: String
        switch damage {
        case "not JSON":
            try Data("{\"action\": ".utf8).write(to: repository.eventURL)
            reason = "The given data was not valid JSON."
        case "no pull request":
            payload.object["pull_request"] = nil
            reason = "pull_request is missing"
        case "no base SHA":
            var base = try #require(pullRequest["base"] as? [String: Any])
            base["sha"] = nil
            pullRequest["base"] = base
            payload.object["pull_request"] = pullRequest
            reason = "pull_request.base.sha is missing"
        default:
            pullRequest["number"] = "21"
            payload.object["pull_request"] = pullRequest
            reason = "pull_request.number has the wrong type: expected Int"
        }
        if damage != "not JSON" {
            try payload.write(to: repository.eventURL)
        }
        let error = await #expect(throws: ContextError.self) {
            try await Context.actions(environment: environment)
        }
        #expect(error == .malformedEventPayload(path: repository.eventURL.path, reason: reason))
    }

    @Test("a commit that isn't a full SHA never reaches git", arguments: [
        ContextError.CommitRole.base, .head, .built,
    ])
    func invalidCommit(role: ContextError.CommitRole) async throws {
        let (repository, commit) = try TestRepository.singleCommit()
        defer { repository.remove() }
        let value = "--output=\(repository.root.path)/written"
        let environment = try repository.actionsEnvironment(
            base: role == .base ? value : commit,
            head: role == .head ? value : commit,
            built: role == .built ? value : commit
        )
        await #expect(throws: ContextError.invalidCommit(role, value: value)) {
            try await Context.actions(environment: environment)
        }
        #expect(!FileManager.default.fileExists(atPath: "\(repository.root.path)/written"))
    }
}

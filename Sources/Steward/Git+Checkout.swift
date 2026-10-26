import Foundation

extension Git {
    /// The root of the working tree around the directory, throwing
    /// `ContextError.notACheckout` when there's none.
    func topLevel() async throws -> String {
        let arguments = ["rev-parse", "--show-toplevel"]
        let outcome = try await run(arguments, into: [UInt8]()) { $0.append(contentsOf: $1) }
        guard outcome.status == 0 else {
            throw ContextError.notACheckout(
                directory: directory,
                message: outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// The full name of the reference `revision` names, following symbolic
    /// ones: `refs/heads/main` for `main`, the current branch for `HEAD`,
    /// `refs/remotes/origin/main` for `origin/HEAD`. Nil for a SHA, an
    /// expression such as `HEAD~1`, a detached `HEAD`, or no such
    /// reference.
    func fullName(of revision: String) async throws -> String? {
        try await value(of: ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", "--end-of-options", revision])
    }

    /// The URL of the remote called `remote`, or nil when there's none.
    func url(ofRemote remote: String) async throws -> String? {
        try await value(of: ["remote", "get-url", "--end-of-options", remote])
    }

    /// A configuration setting's value, such as `user.name`'s, or nil when
    /// it's unset.
    func setting(_ key: String) async throws -> String? {
        try await value(of: ["config", "--get", "--end-of-options", key])
    }

    /// The command's output without its final line break, or nil when it
    /// fails or prints nothing. Failing is how these commands say
    /// "there's none", and a broken repository fails the next command
    /// anyway.
    private func value(of arguments: [String]) async throws -> String? {
        let outcome = try await run(arguments, into: [UInt8]()) { $0.append(contentsOf: $1) }
        let value = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        return outcome.status == 0 && !value.isEmpty ? value : nil
    }
}

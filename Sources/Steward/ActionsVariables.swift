import Foundation

/// The variables GitHub Actions sets for every step, read from an
/// environment.
struct ActionsVariables {
    let environment: [String: String]

    init(_ environment: [String: String]) {
        self.environment = environment
    }

    /// The value of a variable that must be set and not empty.
    func required(_ name: String) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw ContextError.missingEnvironmentVariable(name)
        }
        return value
    }

    /// The value of an `http` or `https` URL variable, or `fallback`, the
    /// value for github.com, when it's unset.
    func url(_ name: String, default fallback: String) throws -> URL {
        let value = environment[name].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              let url = components.url
        else { throw ContextError.invalidURL(variable: name, value: value) }
        return url
    }

    /// `value` in lowercase, as git prints SHAs, if it's a full commit
    /// SHA: 40 hexadecimal digits for SHA-1, 64 for SHA-256.
    static func commit(_ value: String, role: ContextError.CommitRole) throws -> String {
        guard value.utf8.count == 40 || value.utf8.count == 64,
              value.utf8.allSatisfy({ $0.isHexadecimalDigit })
        else { throw ContextError.invalidCommit(role, value: value) }
        return value.lowercased()
    }
}

private extension UInt8 {
    var isHexadecimalDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(self)
    }
}

import Foundation

/// A repository's owner and name, as in `marosoaie/swift-steward`.
struct RepositoryName: Sendable, Hashable, CustomStringConvertible {
    var owner: String
    var name: String

    /// `owner/name`, as `GITHUB_REPOSITORY` and the API's `full_name` have
    /// it.
    var description: String { "\(owner)/\(name)" }

    /// The repository `text` names as `owner/name`, or nil when it isn't
    /// two parts that are neither empty nor `.` or `..`.
    init?(_ text: some StringProtocol) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: \.isWhitespace) })
        else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// The repository a remote's URL points at on `host`, or nil when it's
    /// on another host or isn't a repository's URL there.
    ///
    /// Takes URLs (`https://github.com/o/r.git`, `ssh://git@github.com/o/r`)
    /// and scp-style addresses (`git@github.com:o/r.git`), comparing hosts
    /// without case. A host alias from an SSH configuration isn't
    /// recognized.
    init?(remoteURL: String, host: String) {
        let address: (host: String, path: Substring)?
        if remoteURL.contains("://") {
            address = URLComponents(string: remoteURL).flatMap { components in
                components.host.map { ($0, Substring(components.path)) }
            }
        } else if let colon = remoteURL.firstIndex(of: ":"),
                  !remoteURL[..<colon].contains("/") {
            // scp-style: an optional user, the host, a colon, and the path.
            let authority = remoteURL[..<colon]
            let hostStart = authority.lastIndex(of: "@").map(authority.index(after:)) ?? authority.startIndex
            address = (String(authority[hostStart...]), remoteURL[remoteURL.index(after: colon)...])
        } else {
            address = nil
        }
        guard let address, address.host.lowercased() == host.lowercased() else { return nil }
        let trimmed = address.path.drop { $0 == "/" }
        let withoutSlash = trimmed.hasSuffix("/") ? trimmed.dropLast() : trimmed
        self.init(withoutSlash.hasSuffix(".git") ? withoutSlash.dropLast(4) : withoutSlash)
    }
}

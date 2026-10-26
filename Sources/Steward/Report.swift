import Foundation

/// What one run of a Dangerfile found, ready to render or to hand to a
/// later job.
///
/// It's data, not presentation: findings, not rendered Markdown, so
/// whoever posts it owns the summary's format. As JSON it's a wire
/// contract: the keys are fixed snake case (`schema_version`,
/// `pull_request`, `head_commit`, …), and decoding fails on a newer
/// `schema_version` or an unknown finding kind rather than guess. The run
/// writes it with `--report <path>`, its keys sorted, so a report always
/// encodes to the same bytes.
public struct Report: Sendable, Hashable, Codable {
    /// The `schemaVersion` this version of Steward writes, and the newest
    /// it reads.
    public static let currentSchemaVersion = 1

    /// The version of the JSON format; bumped on any breaking change.
    public var schemaVersion: Int
    /// The base repository, as `owner/name`; empty when a dry run can't
    /// tell.
    public var repository: String
    /// The pull request's number; 0 for a dry run's placeholder.
    public var pullRequest: Int
    /// The SHA of the head commit the findings describe.
    public var headCommit: String
    /// The findings, in rule order, then in the order each rule returned
    /// them.
    public var findings: [Finding]
    /// What wrote the report, such as "Steward", for the log and the
    /// summary's footer.
    public var generator: String

    /// Creates a report from its parts.
    public init(
        schemaVersion: Int = Report.currentSchemaVersion,
        repository: String,
        pullRequest: Int,
        headCommit: String,
        findings: [Finding],
        generator: String
    ) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.pullRequest = pullRequest
        self.headCommit = headCommit
        self.findings = findings
        self.generator = generator
    }

    /// Whether any finding fails the check, so the run exits with status 1.
    public var hasFailures: Bool {
        findings.contains { $0.kind == .failure }
    }

    /// Decodes a report, throwing `DecodingError` for a schema version
    /// this version of Steward doesn't know.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: """
                    schema version \(version) isn't one this Steward reads (1 to \(Self.currentSchemaVersion))
                    """
            )
        }
        self.init(
            schemaVersion: version,
            repository: try container.decode(String.self, forKey: .repository),
            pullRequest: try container.decode(Int.self, forKey: .pullRequest),
            headCommit: try container.decode(String.self, forKey: .headCommit),
            findings: try container.decode([Finding].self, forKey: .findings),
            generator: try container.decode(String.self, forKey: .generator)
        )
    }

    /// The report as `--report` writes it: JSON with sorted keys, indented.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The JSON keys, a wire contract (docs/danger.md, section 4).
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case repository
        case pullRequest = "pull_request"
        case headCommit = "head_commit"
        case findings
        case generator
    }
}

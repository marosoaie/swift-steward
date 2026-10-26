import Foundation
import PullRequestHosting

/// A `pull_request` event's payload, as Actions writes it to the file at
/// `GITHUB_EVENT_PATH`.
///
/// Its pull request decodes with the schema `pulls/get` answers with, and
/// maps to `PullRequest` the same way, so reading it needs no API call.
package struct PullRequestEvent: Sendable, Decodable {
    /// What happened to the pull request: `opened`, `synchronize`,
    /// `edited`, and so on.
    package var action: String
    /// The pull request as it was when the event fired.
    package var pullRequest: PullRequest

    /// Decodes a payload, throwing `DecodingError` when it isn't a pull
    /// request event's.
    package init(payload: Data) throws {
        let decoder = JSONDecoder()
        // As the generated client's default date transcoder decodes them.
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: payload)
    }

    /// Reads the fields Steward needs; the payload has many more.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        pullRequest = PullRequest(try container.decode(Components.Schemas.PullRequest.self, forKey: .pullRequest))
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case pullRequest = "pull_request"
    }
}

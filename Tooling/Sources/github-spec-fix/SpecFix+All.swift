extension SpecFix {
    /// The fixes applied before generation, in order. Each names the
    /// fixture under Tests/GitHubAPITests/Fixtures that fails without it.
    static let all: [SpecFix] = undeclaredResponses + deprecations

    /// Responses GitHub sends that the description doesn't declare. Without
    /// them the client reports `.undocumented(statusCode: 404, _)`, so a
    /// caller can't tell "already deleted" from any other failure by type.
    static let undeclaredResponses: [SpecFix] = [
        SpecFix(
            why: "issues/update-comment answers 404 for a deleted comment (issues-update-comment.macos-update-deleted)",
            edit: .addResponse(
                path: "/repos/{owner}/{repo}/issues/comments/{comment_id}",
                method: "patch",
                status: "404",
                response: "not_found"
            )
        ),
        SpecFix(
            why: "issues/delete-comment answers 404 for a deleted comment (issues-delete-comment.macos-delete-deleted)",
            edit: .addResponse(
                path: "/repos/{owner}/{repo}/issues/comments/{comment_id}",
                method: "delete",
                status: "404",
                response: "not_found"
            )
        ),
    ]

    /// Not discrepancies: the generated memberwise initializers assign these
    /// deprecated properties, which warns under the package's warning-free
    /// rule. The client only decodes these schemas, so the marker buys nothing.
    static let deprecations: [SpecFix] = [
        SpecFix(
            why: "Repository.hasDownloads: deprecated property warns in the generated init",
            edit: .undeprecate(schema: component("repository"), property: "has_downloads")
        ),
        SpecFix(
            why: "Repository.useSquashPrTitleAsDefault: deprecated property warns in the generated init",
            edit: .undeprecate(schema: component("repository"), property: "use_squash_pr_title_as_default")
        ),
        SpecFix(
            why: "RepositoryWebhooks.useSquashPrTitleAsDefault: deprecated property warns in the generated init",
            edit: .undeprecate(schema: component("repository-webhooks"), property: "use_squash_pr_title_as_default")
        ),
    ]
}

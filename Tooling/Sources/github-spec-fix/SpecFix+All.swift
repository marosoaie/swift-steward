extension SpecFix {
    /// The fixes applied before generation, in order. Each names the
    /// fixture under Tests/GitHubAPITests/Fixtures that fails without it.
    static let all: [SpecFix] = deprecations

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

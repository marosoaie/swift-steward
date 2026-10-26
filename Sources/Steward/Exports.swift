// So a Dangerfile needs only `import Steward`. Under MemberImportVisibility,
// a member such as `context.pullRequest.title` is visible only in a file
// that imports the module declaring it, and Swift has no supported way to
// re-export a module. PullRequestHosting isn't a product, so a Dangerfile
// package couldn't import it any other way.
@_exported import GitDiffKit
@_exported import PullRequestHosting

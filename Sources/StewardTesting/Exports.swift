// So a rule test needs only `import StewardTesting` beside the Dangerfile's
// own module: Steward re-exports GitDiffKit and PullRequestHosting in turn,
// for the same reason (see Steward's Exports.swift).
@_exported import Steward

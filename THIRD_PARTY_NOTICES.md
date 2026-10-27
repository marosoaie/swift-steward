# Third-party notices

swift-steward is MIT-licensed ([LICENSE](LICENSE)). A few committed files
come from other projects and keep their own licences; each is listed here
with where its notice lives.

| Path | Upstream | Licence | Notice |
|---|---|---|---|
| `Specs/github/openapi.yaml` | [github/rest-api-description](https://github.com/github/rest-api-description) at the commit `Specs/github/upstream.env` pins, filtered to the operations Steward calls and fixed by `Specs/github/fixes.yaml` | MIT, Copyright (c) 2020 GitHub | [`Specs/github/LICENSE`](Specs/github/LICENSE) |
| `Sources/GitHubAPI/Generated/` | Generated from `Specs/github/openapi.yaml`; its doc comments are GitHub's descriptions | MIT, Copyright (c) 2020 GitHub | [`Specs/github/LICENSE`](Specs/github/LICENSE), named in every file's header |
| `Tests/SwiftStewardTests/Fixtures/swift-pr-70000.diff` | The diff of [swiftlang/swift#70000](https://github.com/swiftlang/swift/pull/70000), unmodified | Apache 2.0 with the Runtime Library Exception, Copyright (c) Apple Inc. and the Swift project authors | [`Tests/SwiftStewardTests/Fixtures/NOTICE`](Tests/SwiftStewardTests/Fixtures/NOTICE) |
| `Tests/SwiftStewardTests/Fixtures/swift-argument-parser-1.5.0/*.log` | Tool output for [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.5.0, quoting lines of its source | Apache 2.0 with the Runtime Library Exception, Copyright (c) Apple Inc. and the Swift project authors | [`Tests/SwiftStewardTests/Fixtures/swift-argument-parser-1.5.0/NOTICE`](Tests/SwiftStewardTests/Fixtures/swift-argument-parser-1.5.0/NOTICE) |

`Tooling/generate-github-api.sh` writes `Specs/github/LICENSE` from
upstream's `LICENSE.md` at the pinned commit, together with the spec and
the generated client, so a new pin brings the licence as it stands there,
and the drift guard fails if the committed copy differs.

## Not listed

- **Downloaded fixtures.** The Linux kernel, redis, and
  swift-argument-parser diffs that the real-world tests read are
  downloaded and cached at test time, never committed.
- **Recorded GitHub responses and event payloads**
  (`Tests/GitHubAPITests/Fixtures`, `Tests/StewardTests/Fixtures`) are
  about the maintainer's own repositories, marosoaie/swift-steward and
  marosoaie/git-diff-parser, including comments that Steward's tests
  posted there.
- **SwiftPM dependencies** (git-diff-parser, swift-argument-parser,
  swift-openapi-runtime, swift-openapi-urlsession, and the generator in
  `Tooling/`) are fetched by SwiftPM, not vendored, and carry their own
  licences.
- **Danger** (MIT) was a model for Steward's concepts only: no code of it
  is copied, and [docs/danger.md](docs/danger.md) names danger-swift's API
  only to map it.

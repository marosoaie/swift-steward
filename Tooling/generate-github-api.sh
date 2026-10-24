#!/bin/sh
# Downloads the pinned GitHub REST description, verifies its checksum,
# filters it to the operations in Specs/github/openapi-generator-config.yaml,
# applies the reviewed fixes, and regenerates Sources/GitHubAPI/Generated.
#
# Usage: Tooling/generate-github-api.sh   (from the repository root)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
specs="$root/Specs/github"
tooling="$root/Tooling"
. "$specs/upstream.env"

cache="$tooling/.build/spec-cache"
spec="$cache/$SPEC_SHA256.json"
mkdir -p "$cache"
if [ ! -f "$spec" ]; then
    curl -sSfL -o "$spec.download" \
        "https://raw.githubusercontent.com/$SPEC_REPO/$SPEC_COMMIT/$SPEC_PATH"
    mv "$spec.download" "$spec"
fi
if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$spec" | cut -d' ' -f1)
else
    actual=$(shasum -a 256 "$spec" | cut -d' ' -f1)
fi
if [ "$actual" != "$SPEC_SHA256" ]; then
    rm -f "$spec"
    echo "error: $SPEC_PATH@$SPEC_COMMIT has SHA-256 $actual, expected $SPEC_SHA256" >&2
    exit 1
fi

swift build --package-path "$tooling" -c release \
    --product swift-openapi-generator >/dev/null
swift build --package-path "$tooling" -c release \
    --product github-spec-fix >/dev/null
bin=$(swift build --package-path "$tooling" -c release --show-bin-path)

"$bin/swift-openapi-generator" filter \
    --config "$specs/openapi-generator-config.yaml" \
    "$spec" > "$specs/filtered.yaml"
"$bin/github-spec-fix" "$specs/filtered.yaml" > "$specs/openapi.yaml"

rm -rf "$root/Sources/GitHubAPI/Generated"
"$bin/swift-openapi-generator" generate \
    --config "$specs/openapi-generator-config.yaml" \
    --output-directory "$root/Sources/GitHubAPI/Generated" \
    "$specs/openapi.yaml"

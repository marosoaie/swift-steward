#!/bin/sh
# Regenerates the GitHub client in one go: downloads the description pinned
# in Specs/github/upstream.env, verifies its SHA-256, filters it to the
# operations in Specs/github/openapi-generator-config.yaml, applies
# Specs/github/fixes.yaml, and generates Sources/GitHubAPI/Generated.
#
# Usage: Tooling/generate-github-api.sh   (from anywhere in the repository)
#
# Writes Specs/github/openapi.yaml (the generator's input, committed) and the
# generated sources only when every step succeeds. The download and the
# filtered description stay in Tooling/.build/spec-cache; `diff` the filtered
# one against openapi.yaml to see exactly what the fixes change.
set -eu

# `filter` decodes vendor extensions (x-github) and examples into
# dictionaries and writes their keys in hash order, which Swift seeds
# randomly per process: without this, every run reorders about 450 lines of
# openapi.yaml, and the drift guard would fail at random. With it, macOS and
# Linux write the same bytes.
export SWIFT_DETERMINISTIC_HASHING=1

root=$(cd "$(dirname "$0")/.." && pwd)
specs="$root/Specs/github"
tooling="$root/Tooling"
generated="$root/Sources/GitHubAPI/Generated"
# shellcheck source=Specs/github/upstream.env
. "$specs/upstream.env"

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Checks the cached copy too: the cache directory is restored by CI and
# writable by anything, and the pin is only as good as this check.
cache="$tooling/.build/spec-cache"
spec="$cache/$SPEC_SHA256.json"
mkdir -p "$cache"
if [ ! -f "$spec" ]; then
    echo "Downloading $SPEC_REPO@$SPEC_COMMIT:$SPEC_PATH"
    curl -sSfL -o "$spec.download" \
        "https://raw.githubusercontent.com/$SPEC_REPO/$SPEC_COMMIT/$SPEC_PATH"
    mv "$spec.download" "$spec"
fi
actual=$(sha256 "$spec")
if [ "$actual" != "$SPEC_SHA256" ]; then
    rm -f "$spec"
    echo "error: $SPEC_PATH at $SPEC_COMMIT has SHA-256 $actual, but Specs/github/upstream.env pins $SPEC_SHA256" >&2
    exit 1
fi

echo "Building the generator and github-spec-fix"
swift build --package-path "$tooling" -c release --product swift-openapi-generator >/dev/null
swift build --package-path "$tooling" -c release --product github-spec-fix >/dev/null
bin=$(swift build --package-path "$tooling" -c release --show-bin-path)

echo "Filtering and fixing the description"
"$bin/swift-openapi-generator" filter \
    --config "$specs/openapi-generator-config.yaml" \
    "$spec" > "$cache/filtered.yaml"
"$bin/github-spec-fix" "$cache/filtered.yaml" \
    --fixes "$specs/fixes.yaml" > "$cache/openapi.yaml"

echo "Generating the client"
rm -rf "$cache/generated"
"$bin/swift-openapi-generator" generate \
    --config "$specs/openapi-generator-config.yaml" \
    --output-directory "$cache/generated" \
    "$cache/openapi.yaml" >/dev/null

cp "$cache/openapi.yaml" "$specs/openapi.yaml"
rm -rf "$generated"
mkdir -p "$(dirname "$generated")"
cp -R "$cache/generated" "$generated"
echo "Wrote Specs/github/openapi.yaml and Sources/GitHubAPI/Generated"

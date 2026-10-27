#!/bin/sh
# Copies the template Dangerfile package to a new directory, as a user
# would, and points its swift-steward dependency at the checkout this
# script is in, so PR CI tests the template against the pull request's
# Steward rather than the main branch the template names.
#
#     Templates/copy-dangerfile.sh <destination>
set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 <destination>" >&2
    exit 64
fi
destination=$1
if [ -e "$destination" ]; then
    echo "error: $destination already exists" >&2
    exit 1
fi

checkout=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$destination"
# Not cp -R: a build of the template in place would come along.
tar -C "$checkout/Templates/Dangerfile" --exclude=./.build --exclude=./.swiftpm -cf - . \
    | tar -C "$destination" -xf -

# `name:` keeps the identity the products are looked up by, whatever the
# checkout's directory is called.
manifest=$destination/Package.swift
escaped=$(printf '%s' "$checkout" | sed 's/[&|\\]/\\&/g')
sed "s|^\( *\)\.package(url: \"https://github.com/marosoaie/swift-steward.git\", [^)]*)|\1.package(name: \"swift-steward\", path: \"$escaped\")|" \
    "$manifest" > "$manifest.new"
mv "$manifest.new" "$manifest"
if ! grep -qF "path: \"$checkout\")" "$manifest"; then
    echo "error: $manifest has no swift-steward dependency to point at $checkout" >&2
    exit 1
fi

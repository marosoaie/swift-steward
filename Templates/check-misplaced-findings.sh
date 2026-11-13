#!/bin/sh
# Checks that findings written among a Dangerfile's rules, outside any
# rule, fail to build with RuleBuilder's message saying where they belong,
# rather than an error about its overloads. It adds a source file of such
# findings to a copy of the template Dangerfile package, so run it on one
# made by copy-dangerfile.sh, after the copy's own build, tests and dry run:
#
#     Templates/check-misplaced-findings.sh <copy>
set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 <copy>" >&2
    exit 64
fi
package=$1
source=$package/Sources/Dangerfile/MisplacedFindings.swift
log=$(mktemp)
trap 'rm -f "$source" "$log"' EXIT

cat > "$source" <<'SWIFT'
import Steward

enum MisplacedFindings {
    @RuleBuilder static var qualified: [Rule] { Finding.warning("qualified") }
    @RuleBuilder static var implicit: [Rule] { .warning("implicit") }
    @RuleBuilder static var literal: [Rule] { [.warning("literal")] }
    static let findings: [Finding] = [.warning("value")]
    @RuleBuilder static var value: [Rule] { findings }
}
SWIFT

if swift build --package-path "$package" --target Dangerfile > "$log" 2>&1; then
    echo "error: findings outside any rule built" >&2
    exit 1
fi
# Each error once, whatever the compiler's diagnostic style repeats.
errors() {
    grep -E "MisplacedFindings\.swift:[0-9]+:[0-9]+: .*error: .*$1" "$log" | sort -u | wc -l | tr -d ' '
}
finding=$(errors 'a finding belongs inside a rule')
findings=$(errors 'findings belong inside a rule')
if [ "$finding" -ne 2 ] || [ "$findings" -ne 2 ]; then
    cat "$log" >&2
    echo "error: expected RuleBuilder's message for each of 4 misplaced findings, found $finding and $findings" >&2
    exit 1
fi
echo "Each misplaced finding fails with RuleBuilder's message."

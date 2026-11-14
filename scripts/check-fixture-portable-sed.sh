#!/usr/bin/env bash
set -uo pipefail

# Every guard fixture must edit a file in place in a way that works with both
# GNU sed (Linux, CI) and BSD sed (macOS, the maintainer and the steward).
#
# The two disagree on the in-place flag. GNU sed takes the flag alone; BSD sed
# reads the next word as a backup suffix, so a GNU-style call either fails or
# leaves a stray backup file named after the script. Nineteen fixtures went
# red on macOS for this reason while CI stayed green.
#
# scripts/check-guards.sh defines `sed_inplace`, which writes to a temporary
# file and copies it back, and every fixture uses it. This guard fails when a
# fixture calls sed with an in-place option directly. It reads only the lines
# that are not comments, so a fixture can describe the rule in prose.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

fixture_dir="scripts/guard-fixtures"

# A sed word (not part of a longer name such as sed_inplace), then any words
# of the same command (options or a script, up to a pipe, `;` or `&`), then one
# option that holds the in-place letter, or the long form. A call split over
# lines with a backslash is read one line at a time, so its flags must be on
# the line that names sed.
pattern='(^|[^[:alnum:]_])sed([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+(-[[:alpha:]]*i|--in-place)'

hits="$(
    for f in "$fixture_dir"/*.fixture; do
        [ -e "$f" ] || continue
        grep -nE "$pattern" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
    done
)"

if [ -n "$hits" ]; then
    echo "ERROR: a guard fixture calls sed with an in-place option directly."
    echo "       GNU sed and BSD sed (macOS) do not agree on that option, so the"
    echo "       fixture fails on macOS or leaves a backup file. Use sed_inplace,"
    echo "       which scripts/check-guards.sh defines, with the same sed script:"
    echo
    printf '%s\n' "$hits" | sed 's/^/    /'
    exit 1
fi

echo "check-fixture-portable-sed: OK (no fixture calls sed in place directly)"

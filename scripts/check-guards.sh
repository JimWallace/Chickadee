#!/usr/bin/env bash
set -uo pipefail

# Guard self-test: every guard must be SEEN to fail.
#
# The house rule is already written — "a check never seen to fail is not a
# check" (docs/ui-ratchet-handoff.md) — and it is the one discipline here with
# nothing enforcing it. The cost of that gap is on the record four times: a
# regression test matching a wiring string after the wiring went dead, the
# repaint probe's filter assertion passing against a dead poll, the S5 guard
# matching its own documentation, and a hover-budget test that passed three
# times while exercising nothing. Each read as coverage. None was.
#
# This closes it mechanically. Each fixture in scripts/guard-fixtures/ names a
# guard, a defect that guard exists to catch, and the message it must produce.
# The runner applies the defect, runs the guard, and FAILS THE BUILD IF THE
# GUARD PASSES. A guard that stops catching its own defect — because a regex
# drifted, a path moved, a rule was refactored into a no-op — is then a red
# build rather than a quiet false negative.
#
# Two design points worth keeping.
#
#   * The expected MESSAGE is asserted, not just the exit status. A fixture
#     that trips a different rule in the same script would otherwise look like
#     a pass, and the guard under test would still be dead.
#   * A fixture edits the real tree and restores it. Only the files it declares
#     are touched, they are restored on every exit path including a failed
#     assertion or an interrupt, and the runner refuses to start if any of them
#     is already modified — so a dirty working tree is never silently reverted.
#
# Fixture format (scripts/guard-fixtures/NAME.fixture, sourced):
#
#     guard="scripts/check-design-tokens.sh"   # the guard to run
#     files="Public/styles.css"                # files apply() modifies
#     description="a raw hex colour in a rule body"
#     expect="colour literal"                  # substring its output must have
#     apply() { ... }                          # introduce the defect
#
# Adding a rule to a guard means adding a fixture. That is the price of the
# rule, and it is the cheapest possible: proving once that the thing you just
# wrote can fail.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fixture_dir="scripts/guard-fixtures"
backup_dir="$(mktemp -d)"
current_files=""
status=0
passed=0
failed=0

restore_current() {
    [ -z "$current_files" ] && return 0
    for f in $current_files; do
        if [ -f "$backup_dir/$(echo "$f" | tr '/' '_')" ]; then
            cp "$backup_dir/$(echo "$f" | tr '/' '_')" "$f"
        fi
    done
    current_files=""
}

cleanup() {
    restore_current
    rm -rf "$backup_dir"
}
trap cleanup EXIT INT TERM

if [ ! -d "$fixture_dir" ]; then
    echo "ERROR: no fixture directory at $fixture_dir"
    exit 1
fi

fixtures=("$fixture_dir"/*.fixture)
if [ ! -e "${fixtures[0]}" ]; then
    echo "ERROR: $fixture_dir contains no fixtures."
    echo "       An empty self-test suite reports success while proving nothing,"
    echo "       which is the exact failure this script exists to prevent."
    exit 1
fi

echo "check-guards: ${#fixtures[@]} fixtures"

# Pre-flight: every guard under test must be GREEN on the clean tree, once.
# A guard already failing would make every result below meaningless — a red
# run would prove nothing about the fixture that "caused" it. Hoisted out of
# the loop because the umbrella guard costs seconds and fixtures restore the
# tree, so one clean run covers them all.
guards_under_test="$(
    for f in "${fixtures[@]}"; do
        # shellcheck disable=SC1090
        ( source "$f"; printf '%s\n' "$guard" )
    done | sort -u
)"
for g in $guards_under_test; do
    if ! "./$g" >/dev/null 2>&1; then
        echo
        echo "ERROR: $g already fails on the clean tree."
        echo "       Fix that first; until then no fixture result means anything."
        exit 1
    fi
done
echo "pre-flight: $(wc -w <<<"$guards_under_test" | tr -d ' ') guards green on the clean tree"
echo

for fixture in "${fixtures[@]}"; do
    name="$(basename "$fixture" .fixture)"

    # Read the fixture's metadata in a subshell so one fixture cannot leak
    # variables or an apply() into the next.
    meta="$(
        # shellcheck disable=SC1090
        source "$fixture"
        printf '%s\n%s\n%s\n%s\n' "$guard" "$files" "$description" "$expect"
    )"
    guard="$(sed -n 1p <<<"$meta")"
    files="$(sed -n 2p <<<"$meta")"
    description="$(sed -n 3p <<<"$meta")"
    expect="$(sed -n 4p <<<"$meta")"

    if [ ! -x "$guard" ] && [ ! -f "$guard" ]; then
        echo "✘ $name — names a guard that does not exist: $guard"
        failed=$((failed + 1)); status=1; continue
    fi

    # Refuse to touch a file the working tree has already modified.
    #
    # `git diff --quiet` exits 0 clean, 1 differing, and >1 on an ERROR — and
    # an error is routine in CI, where the container runs as root against a
    # workspace owned by another uid and git refuses the repository as
    # "dubious ownership". Treating every non-zero as "modified" made this
    # refuse all 18 fixtures on a pristine checkout. When git cannot answer,
    # proceed: the backup/restore below is what actually protects the file,
    # and this check only exists to avoid confusing results mid-edit.
    dirty=""
    git_mute=""
    for f in $files; do
        if [ ! -f "$f" ]; then
            dirty="$f (missing)"
            break
        fi
        git diff --quiet -- "$f" 2>/dev/null; unstaged=$?
        git diff --cached --quiet -- "$f" 2>/dev/null; staged=$?
        if [ "$unstaged" -gt 1 ] || [ "$staged" -gt 1 ]; then
            git_mute="yes"
        elif [ "$unstaged" -eq 1 ] || [ "$staged" -eq 1 ]; then
            dirty="$f (modified)"
            break
        fi
    done
    if [ -n "$git_mute" ] && [ -z "${git_mute_warned:-}" ]; then
        echo "note: git cannot report file status here; relying on backup/restore."
        git_mute_warned=1
    fi
    if [ -n "$dirty" ]; then
        echo "✘ $name — refusing to run: $dirty"
        echo "    This fixture edits and restores that file; commit or stash first."
        failed=$((failed + 1)); status=1; continue
    fi

    for f in $files; do
        cp "$f" "$backup_dir/$(echo "$f" | tr '/' '_')"
    done
    current_files="$files"

    ( # shellcheck disable=SC1090
      source "$fixture"; apply )

    out="$("./$guard" 2>&1)"
    code=$?
    restore_current

    if [ "$code" -eq 0 ]; then
        echo "✘ $name — $guard PASSED with the defect applied."
        echo "    defect: $description"
        echo "    This guard no longer catches what it exists to catch."
        failed=$((failed + 1)); status=1
    elif ! grep -qF -- "$expect" <<<"$out"; then
        echo "✘ $name — $guard failed, but not with its own message."
        echo "    defect:   $description"
        echo "    expected: $expect"
        echo "    The defect tripped a different rule, so the rule under test"
        echo "    is still unproven."
        printf '%s\n' "$out" | sed 's/^/      /' | head -12
        failed=$((failed + 1)); status=1
    else
        echo "✔ $name — $description"
        passed=$((passed + 1))
    fi
done

echo
if [ "$status" -eq 0 ]; then
    echo "check-guards: OK ($passed guards seen to fail on their own defect)"
else
    echo "check-guards: $failed of $((passed + failed)) fixtures did not prove their guard"
fi
exit "$status"

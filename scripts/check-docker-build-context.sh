#!/usr/bin/env bash
set -euo pipefail

# Every directory the Docker compile stage needs must be IN the build context.
#
# WHY THIS IS A GUARD. The Dockerfile has two ways to obtain binaries.
# `BINARIES=prebuilt` copies artifacts the `build-release` job produced from a
# plain checkout, and that is what every push builds — so the compile stage is
# exercised by exactly one thing: `docker compose up --build`, which runs
# WEEKLY, in the ZAP baseline workflow. A directory added to Package.swift and
# not added to the Dockerfile therefore breaks nothing anybody sees for up to a
# week, and then breaks a schedule-only run whose failure reads as a ZAP
# problem rather than a build one.
#
# That is not hypothetical. `Plugins/EmbedRunnerSupport` was added with no
# matching COPY, and the compile stage died on
#
#     error: invalid custom path 'Plugins/EmbedRunnerSupport' for target
#     'EmbedRunnerSupport'
#
# which SPM raises for EVERY product — it validates all target paths in the
# manifest, including targets it is not building — so the image could not be
# built at all while every PR stayed green.
#
# WHAT IT DERIVES. Nothing here is a list of directories. The requirements come
# from the two places that already own the answer:
#
#   * every `path:` a target declares in Package.swift, and
#   * every package-relative directory a build-tool plugin reads, walked out of
#     the `context.package.directoryURL.appending(path:)` chains in the plugin
#     sources. That is how Tools/runner-support is required: the manifest never
#     mentions it, and only the plugin knows it is an input.
#
# Both derivations assert they found something, because a derivation that
# silently returns nothing is indistinguishable from a passing check — the
# #1330 lesson, paid for by five red releases.
#
# WHAT IT CHECKS. For each required path: a COPY in the compile stage brings it
# in (itself or an ancestor), and .dockerignore does not exclude it. The second
# half matters on its own — `COPY Tools/runner-support` fails at build time if
# .dockerignore has already dropped the directory from the context, and the
# error names the COPY rather than the ignore rule.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
    echo "ERROR: $1"
    echo
    shift
    for line in "$@"; do echo "  $line"; done
    echo
    echo "Add a COPY to the Dockerfile's compile stage, and make sure"
    echo ".dockerignore does not exclude the path."
    exit 1
}

# ── What the build needs ────────────────────────────────────
# Target paths declared in the manifest.
manifest_paths=$(grep -oE 'path:[[:space:]]*"[^"]+"' Package.swift \
    | sed -E 's/.*"(.*)"/\1/' | sort -u)

[ -n "$manifest_paths" ] || fail "no target paths parsed out of Package.swift" \
    "The manifest declares targets with path:, so this found nothing because" \
    "the parse broke — not because there is nothing to check."

# Directories a build-tool plugin reads, as
# `context.package.directoryURL` followed by one or more `.appending(path:)`.
# Each chain yields one package-relative path; a plugin that mentions the
# package directory and yields none is a parse failure, not a pass.
plugin_paths=""
for plugin_source in $(find Plugins -name '*.swift' 2>/dev/null | sort); do
    grep -q 'context\.package\.directoryURL' "$plugin_source" || continue
    found=$(awk '
        /context\.package\.directoryURL/ { chain = ""; active = 1; next }
        active && match($0, /\.appending\(path: "[^"]+"\)/) {
            seg = substr($0, RSTART, RLENGTH)
            sub(/^\.appending\(path: "/, "", seg)
            sub(/"\)$/, "", seg)
            chain = (chain == "" ? seg : chain "/" seg)
            next
        }
        active { if (chain != "") print chain; active = 0; chain = "" }
        END { if (active && chain != "") print chain }
    ' "$plugin_source" | sort -u)
    [ -n "$found" ] || fail "no package-relative path parsed out of $plugin_source" \
        "It reads context.package.directoryURL, so it names at least one" \
        "directory the build context must carry. The parse found none."
    plugin_paths=$(printf '%s\n%s\n' "$plugin_paths" "$found")
done

required=$(printf '%s\n%s\n' "$manifest_paths" "$plugin_paths" \
    | grep -v '^$' | sort -u)

# ── What the compile stage copies ───────────────────────────
# COPY sources between `FROM ... AS compile` and the next FROM. The last
# argument of a COPY is its destination.
copied=$(awk '
    /^FROM .* AS compile/ { in_compile = 1; next }
    /^FROM / { in_compile = 0 }
    in_compile && /^COPY / {
        for (i = 2; i < NF; i++) print $i
    }
' Dockerfile | sort -u)

[ -n "$copied" ] || fail "no COPY sources parsed out of the compile stage" \
    "The stage exists and copies files, so this found nothing because the" \
    "parse broke — not because the stage copies nothing."

# ── Check ───────────────────────────────────────────────────
# .dockerignore: last matching pattern wins, as Docker evaluates it. A pattern
# matches a required path when it names the path or one of its ancestors,
# with or without a trailing /* or /.
ignored_by() {
    local path="$1" verdict="" line pattern negated prefix
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [ -z "$line" ] && continue
        negated=0
        case "$line" in !*) negated=1; line="${line#!}" ;; esac
        pattern="${line%/}"
        pattern="${pattern%/\*}"
        prefix="$path"
        while [ -n "$prefix" ] && [ "$prefix" != "." ]; do
            if [ "$pattern" = "$prefix" ]; then
                verdict=$([ "$negated" -eq 1 ] && echo "include" || echo "exclude")
                break
            fi
            prefix="$(dirname "$prefix")"
        done
    done < .dockerignore
    [ "$verdict" = "exclude" ]
}

for path in $required; do
    # Existence is the parse's own sanity check. Every path here was derived
    # from a manifest SPM already validates or from a directory a plugin reads,
    # so one that is not on disk means the derivation produced nonsense — and a
    # derivation that quietly yields nonsense passes for the same reason an
    # empty one does.
    [ -e "$path" ] || fail "derived a path that does not exist: '"'"'$path'"'"'" \
        "It came from Package.swift or a plugin source, so either the parse" \
        "broke or the path is stale. Both are failures, not paths to skip."

    covered=0
    for src in $copied; do
        src="${src%/}"
        case "$path/" in "$src"/*) covered=1 ;; esac
    done
    [ "$covered" -eq 1 ] || fail \
        "the Docker compile stage does not copy '$path'" \
        "SPM validates every target path in Package.swift, and a build-tool" \
        "plugin reads its inputs from the package directory. A path missing" \
        "from the context fails the image build for every product."

    if ignored_by "$path"; then
        fail ".dockerignore excludes '$path', which the compile stage copies" \
            "The COPY will fail at build time naming the path, not the ignore" \
            "rule that dropped it. Re-include it with a ! pattern (exclude the" \
            "siblings as 'Dir/*' so the parent stays in the context)."
    fi
done

count=$(echo "$required" | grep -c . || true)
echo "check-docker-build-context: OK ($count required path(s) in the compile context)"

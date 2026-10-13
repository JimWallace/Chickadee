#!/usr/bin/env bash
set -euo pipefail

# Class-resolution guard (invoked from check-styles.sh).
#
# Every class name a view or first-party script ASSIGNS must resolve to a
# stylesheet rule, a `js-` behaviour-hook prefix, or the allowlist — because a
# class that resolves to nothing is indistinguishable from a working one in
# every existing check. Two shipped bugs motivated this: suite-table.js
# toggled section-drop-before/-after during section drags and no stylesheet
# defined them (no drop indicator rendered, ever), and admin-brightspace used
# a .btn-secondary that exists nowhere (silently rendering as plain .btn).
#
# What counts as a REFERENCE (assignment sites only — querySelector reads are
# deliberately out of scope, they follow the assignments):
#   * the string literals of every `.class(…)` call in an Elementary view
#     (Sources/APIServer/Views/**/*.swift), including the literals of a
#     ternary inside the call or inside an interpolation
#   * class="…" attribute values inside strings in top-level Public/*.js
#   * classList.add('…', …) and className = '…' in top-level Public/*.js
#
# What counts as DEFINED: any `.name` class token appearing in Public/*.css or
# in a view's PageStyle block.
#
# ElementaryPageGuardTests applies the same rule to rendered pages, which
# sees a name built from a value; this sees every branch, rendered or not.
#
# Escapes, by design:
#   * a name glued to an interpolation (`status-\(s)`) is skipped —
#     interpolated families like that are covered by the Swift
#     exhaustiveness test (StatusClassStylesheetTests), not this guard;
#   * names starting with js- are behaviour hooks, never styled, always OK;
#   * scripts/class-resolution-allowlist.txt lists the pre-existing
#     behaviour-only hooks that predate the js- convention. Shrink-only:
#     remove entries as they are renamed or styled, never add one for a new
#     class — new behaviour hooks take the js- prefix.
#
# The extractor asserts its own completeness: zero extracted references or
# zero defined classes means the extractor broke, and that fails the check
# rather than passing vacuously (the #1330 lesson).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=lib/css.sh
. "scripts/lib/css.sh"

allowlist_file="scripts/class-resolution-allowlist.txt"
swift_views=()
while IFS= read -r f; do swift_views+=("$f"); done < <(swift_view_files)
style_views=()
while IFS= read -r f; do style_views+=("$f"); done < <(swift_page_style_files)

# ── Defined classes ──────────────────────────────────────────────────────────
defined="$(
  {
    cat Public/*.css
    page_style_blocks "${style_views[@]}"
  } \
    | strip_css_comments \
    | grep -oE '\.[a-z][a-z0-9-]*' \
    | sed 's/^\.//' | sort -u
)"

# ── Referenced classes ───────────────────────────────────────────────────────
# 1. The string literals of each `.class(…)` call in a Swift view. The walk
#    tracks strings, interpolations and parentheses, so it reads a call that
#    spans lines, every literal of a ternary (`.class(open ? "a b" : "a")`),
#    and a literal inside an interpolation (`"card \(open ? "is-open" : "")"`).
#    An interpolation becomes `_` in the literal around it, which no class
#    name holds, so a name glued to one (`status-\(s)`) stays out of reach;
#    the rendered-page test reads that one.
swift_refs="$(swift_call_literals '.class(' ' ' "${swift_views[@]}" | cut -f2 | tr ' ' '\n')"

# 2. class="…" values in first-party JS: class attributes inside
#    generated-HTML strings.
attr_refs="$(
  grep -rhoE 'class="[^"]*"' Public/*.js 2>/dev/null \
    | sed -E 's/^class="//; s/"$//' \
    | tr ' ' '\n'
)"

# 2. classList.add('a', "b", …) — SIMPLE literal arg lists only.  A call whose
#    args contain a ternary or identifier is skipped entirely (erring to false
#    negatives): pulling every quoted string out of
#    classList.add(dir === 'asc' ? 'sort-asc' : 'sort-desc') would report the
#    comparison operand 'asc' as a class.
clsadd_refs="$(
  grep -rhoE "classList\.add\(\s*(['\"][a-z][a-z0-9-]*['\"]\s*,\s*)*['\"][a-z][a-z0-9-]*['\"]\s*\)" Public/*.js 2>/dev/null \
    | grep -oE "'[^']+'|\"[^\"]+\"" | sed -E "s/^['\"]//; s/['\"]$//" \
    | tr ' ' '\n'
)"

# 3. className = '…' assignments.
clsname_refs="$(
  grep -rhoE "className *= *['\"][^'\"]*['\"]" Public/*.js 2>/dev/null \
    | sed -E "s/^className *= *['\"]//; s/['\"]$//" \
    | tr ' ' '\n'
)"

referenced="$(
  printf '%s\n%s\n%s\n%s\n' "$swift_refs" "$attr_refs" "$clsadd_refs" "$clsname_refs" \
    | grep -E '^[a-z][a-z0-9-]*$' \
    | sort -u
)"

# ── Completeness self-check ──────────────────────────────────────────────────
if [ -z "$defined" ] || [ -z "$referenced" ] || [ -z "$(grep -E '^[a-z][a-z0-9-]*$' <<< "$swift_refs" || true)" ]; then
  echo "ERROR: check-class-resolution extracted nothing (defined, referenced or Swift view set is empty)."
  echo "       The extractor is broken; fix it rather than trusting a vacuous pass."
  exit 1
fi

allowlist=""
if [ -f "$allowlist_file" ]; then
  allowlist="$(grep -vE '^\s*(#|$)' "$allowlist_file" | sort -u)"
fi

status=0
unresolved=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  case "$name" in js-*) continue ;; esac
  if grep -qxF -- "$name" <<< "$defined"; then continue; fi
  if [ -n "$allowlist" ] && grep -qxF -- "$name" <<< "$allowlist"; then continue; fi
  unresolved+="  ${name}"$'\n'
done <<< "$referenced"

if [ -n "$unresolved" ]; then
  status=1
  echo "ERROR: class name(s) assigned in a Swift view or Public/*.js resolve to no stylesheet rule."
  echo "       Style the class, rename a behaviour-only hook with the js- prefix,"
  echo "       or (pre-existing hooks only) keep it in ${allowlist_file}."
  printf '%s' "$unresolved"
  echo
fi

# Allowlist hygiene: an entry that gained a stylesheet rule (or stopped being
# referenced) is stale — prune it so the list only shrinks.
stale=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if grep -qxF -- "$name" <<< "$defined"; then
    stale+="  ${name} (now defined in a stylesheet)"$'\n'
  elif ! grep -qxF -- "$name" <<< "$referenced"; then
    stale+="  ${name} (no longer referenced)"$'\n'
  fi
done <<< "$allowlist"
if [ -n "$stale" ]; then
  status=1
  echo "ERROR: stale allowlist entr(y/ies) in ${allowlist_file} — remove them:"
  printf '%s' "$stale"
  echo
fi

if [ "$status" -eq 0 ]; then
  ref_count="$(printf '%s\n' "$referenced" | grep -c . || true)"
  echo "check-class-resolution: OK (${ref_count} class names, all resolve)"
fi

exit "$status"

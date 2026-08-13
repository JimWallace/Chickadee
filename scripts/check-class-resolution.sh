#!/usr/bin/env bash
set -euo pipefail

# Class-resolution guard (invoked from check-styles.sh).
#
# Every class name a template or first-party script ASSIGNS must resolve to a
# stylesheet rule, a `js-` behaviour-hook prefix, or the allowlist — because a
# class that resolves to nothing is indistinguishable from a working one in
# every existing check. Two shipped bugs motivated this: suite-table.js
# toggled section-drop-before/-after during section drags and no stylesheet
# defined them (no drop indicator rendered, ever), and admin-brightspace used
# a .btn-secondary that exists nowhere (silently rendering as plain .btn).
#
# What counts as a REFERENCE (assignment sites only — querySelector reads are
# deliberately out of scope, they follow the assignments):
#   * class="…" attribute values in Resources/Views/*.leaf
#   * class="…" attribute values inside strings in top-level Public/*.js
#   * classList.add('…', …) and className = '…' in top-level Public/*.js
#
# What counts as DEFINED: any `.name` class token appearing in Public/*.css or
# in a template <style> block.
#
# Escapes, by design:
#   * tokens containing Leaf syntax (anything not [a-z0-9-]) are skipped —
#     interpolated families like status-#(…) are covered by the Swift
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

views=(Resources/Views/*.leaf)
allowlist_file="scripts/class-resolution-allowlist.txt"

# ── Defined classes ──────────────────────────────────────────────────────────
defined="$(
  {
    cat Public/*.css
    for f in "${views[@]}"; do sed -n '/<style>/,/<\/style>/p' "$f"; done
  } \
    | sed -E 's#/\*[^*]*\*+([^/*][^*]*\*+)*/##g' \
    | grep -oE '\.[a-z][a-z0-9-]*' \
    | sed 's/^\.//' | sort -u
)"

# ── Referenced classes ───────────────────────────────────────────────────────
# 1. class="…" values in templates and first-party JS (the JS hits are
#    class attributes inside generated-HTML strings).
attr_refs="$(
  grep -rhoE 'class="[^"]*"' "${views[@]}" Public/*.js 2>/dev/null \
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
  printf '%s\n%s\n%s\n' "$attr_refs" "$clsadd_refs" "$clsname_refs" \
    | grep -E '^[a-z][a-z0-9-]*$' \
    | sort -u
)"

# ── Completeness self-check ──────────────────────────────────────────────────
if [ -z "$defined" ] || [ -z "$referenced" ]; then
  echo "ERROR: check-class-resolution extracted nothing (defined or referenced set is empty)."
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
  if printf '%s\n' "$defined" | grep -qxF -- "$name"; then continue; fi
  if [ -n "$allowlist" ] && printf '%s\n' "$allowlist" | grep -qxF -- "$name"; then continue; fi
  unresolved+="  ${name}"$'\n'
done <<< "$referenced"

if [ -n "$unresolved" ]; then
  status=1
  echo "ERROR: class name(s) assigned in a template or Public/*.js resolve to no stylesheet rule."
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
  if printf '%s\n' "$defined" | grep -qxF -- "$name"; then
    stale+="  ${name} (now defined in a stylesheet)"$'\n'
  elif ! printf '%s\n' "$referenced" | grep -qxF -- "$name"; then
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

#!/usr/bin/env bash
set -euo pipefail

# CSS custom-property guard (pure grep/sed — no python, so it runs in the
# Swift CI container alongside the other format-lint steps).
#
# Two failure classes, both regressions the v0.4.x UI-cleanup pass fixed and
# that render fine in the browser (so no test catches them):
#
#   1. UNDEFINED VAR: a `var(--x)` whose `--x` is never declared in a
#      stylesheet AND has no inline fallback.  It silently resolves to the
#      property's initial value — e.g. `--muted` / `--meta` were undefined, so
#      "muted" text rendered in full-strength body colour.
#
#   2. DEAD HEX FALLBACK: `var(--x, #rrggbb)`.  A hardcoded colour fallback is
#      either dead weight (the var IS defined) or an off-palette, dark-mode-
#      unaware value that bypasses the design system.  Define the var and drop
#      the fallback.  Non-colour fallbacks (e.g. `var(--filter-width, 16rem)`
#      for a var assigned inline in markup) are allowed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

css_files=(Public/*.css)
usage_files=(Resources/Views/*.leaf Public/*.css Public/*.js)

# Declared properties: `--name:` only ever appears as a declaration — var()
# usages have no colon after the name — so this captures declarations alone.
declared="$(grep -hroE -- '--[A-Za-z0-9_-]+[[:space:]]*:' "${css_files[@]}" \
            | sed -E 's/[[:space:]]*:$//' | sort -u)"

status=0

# 1. Undefined: `var(--x)` with no fallback (")" right after the name), where
#    --x is not declared.
undefined=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  name="$(printf '%s' "$hit" | sed -E 's/.*var\([[:space:]]*(--[A-Za-z0-9_-]+)[[:space:]]*\).*/\1/')"
  if ! printf '%s\n' "$declared" | grep -qxF -- "$name"; then
    undefined+="  ${hit}"$'\n'
  fi
done < <(grep -rnoE 'var\([[:space:]]*--[A-Za-z0-9_-]+[[:space:]]*\)' "${usage_files[@]}" || true)

if [ -n "$undefined" ]; then
  status=1
  echo "ERROR: var() references an undefined custom property (no fallback)."
  echo "       Declare it in Public/styles.css (with a dark-mode value if it's a colour)."
  printf '%s' "$undefined"
  echo
fi

# 2. Dead hex fallback: `var(--x, … #hex …)`.
deadhex="$(grep -rnoE 'var\([[:space:]]*--[A-Za-z0-9_-]+[[:space:]]*,[^)]*#[0-9a-fA-F]{3,8}[^)]*\)' \
           "${usage_files[@]}" || true)"
if [ -n "$deadhex" ]; then
  status=1
  echo "ERROR: var(--x, #hex) uses a hardcoded colour fallback."
  echo "       Define the variable in the palette and drop the fallback so it"
  echo "       routes through the design system (and adapts to dark mode)."
  printf '%s\n' "$deadhex" | sed 's/^/  /'
  echo
fi

if [ "$status" -eq 0 ]; then
  decl_count="$(printf '%s\n' "$declared" | grep -c . || true)"
  echo "check-css-vars: OK (${decl_count} vars declared, all references resolve)"
fi

exit "$status"

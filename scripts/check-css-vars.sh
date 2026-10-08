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
  if ! grep -qxF -- "$name" <<< "$declared"; then
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

# 3. A grey step with no dark value. The grey scale inverts in dark mode, so a
#    step that only the light :root declares keeps its light value on a dark
#    surface: --gray-300 did, and every border drawn with it showed near white
#    (#2401). Each --gray-N in the light :root must also be declared in the
#    prefers-color-scheme block and in :root[data-theme="dark"].
block_decls() {
  awk -v open="$1" '
    !inside && index($0, open) == 1 { inside = 1; next }
    inside && /^}/ { exit }
    inside { print }
  ' Public/styles.css | grep -oE -- '--gray-[0-9]+[[:space:]]*:' | sed -E 's/[[:space:]]*:$//' | sort -u
}
light_grays="$(block_decls ':root {')"
missing_dark=""
for open in '@media (prefers-color-scheme: dark) {' ':root[data-theme="dark"] {'; do
  dark_grays="$(block_decls "$open")"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    grep -qxF -- "$name" <<< "$dark_grays" || missing_dark+="  ${name} (missing from: ${open%" {"})"$'\n'
  done <<< "$light_grays"
done
if [ -z "$light_grays" ]; then
  status=1
  echo "ERROR: found no --gray-N declarations in the light :root block of Public/styles.css."
  echo "       This check is not reading the stylesheet."
elif [ -n "$missing_dark" ]; then
  status=1
  echo "ERROR: a grey step has no dark-mode value."
  echo "       Declare it in both dark blocks of Public/styles.css."
  printf '%s' "$missing_dark"
  echo
fi

if [ "$status" -eq 0 ]; then
  decl_count="$(printf '%s\n' "$declared" | grep -c . || true)"
  echo "check-css-vars: OK (${decl_count} vars declared, all references resolve)"
fi

exit "$status"

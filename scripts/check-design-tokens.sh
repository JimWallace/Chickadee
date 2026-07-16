#!/usr/bin/env bash
set -euo pipefail

# Design-token guard (pure grep/sed/awk — runs in the Swift CI container
# alongside the other format-lint steps; invoked from check-styles.sh).
#
# Locks in the UI-consistency invariants from the design-token pass (see
# docs/ui-design.md).  The historical drift this prevents: 26 distinct
# font-size values and 18 distinct border-radius values had accumulated
# across the global sheet and page <style> blocks, plus off-palette hex
# colours (Bootstrap-green flash banners, one-off reds) that ignored dark
# mode.  None of it is caught by the render tests — everything renders —
# so it needs a static guard.  Four rules:
#
#   1. COLOUR PLACEMENT: a raw colour literal — #hex, rgb()/rgba(),
#      hsl()/hsla() — may appear ONLY as the value of a custom-property
#      declaration (`--x: #hex`) in Public/*.css — i.e. in the palette.
#      Rule bodies and page <style> blocks must use var(--x) so every
#      colour routes through the palette and adapts to dark mode.
#
#   2. TYPE SCALE: every `font-size:` value must be a var(--text-*) token,
#      an em value (relative sizing inside a component, e.g. `code`,
#      superscripts, display glyphs), or `inherit`.  Pick the nearest
#      token step; do not introduce a new rem/px literal.
#
#   3. RADIUS SCALE: every `border-radius:` value must be a var(--radius-*)
#      token, `0`, `50%` (circles), or a multi-value corner shorthand.
#
#   4. SPACING LATTICE: every rem component of a padding/margin/gap value
#      must be one of the steps below.  This is a ratchet, not a scale (33
#      steps had accumulated; converged to 26): remove steps as usage dies,
#      never add one for a one-off — pick the nearest existing step.
#      px hairlines (1px/-1px), 0, auto, %, and calc()/clamp() are outside
#      the rule.  Preferred steps for NEW code are in docs/ui-design.md.
#
# Scope: Public/*.css + <style> blocks in Resources/Views/*.leaf.  The
# token scales themselves are declared in Public/styles.css (`--text-*`,
# `--radius-*`); check-css-vars.sh separately asserts every var() resolves.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

css_files=(Public/*.css)
views=(Resources/Views/*.leaf)
status=0

# The spacing lattice (rule 4).  Shrink-only — see the header comment.
SPACING_STEPS=" -.25rem -.75rem .1rem .15rem .2rem .25rem .3rem .35rem .4rem .45rem .5rem .55rem .6rem .75rem .8rem .85rem .9rem 1rem 1.1rem 1.25rem 1.5rem 2rem 2.5rem 3rem 4rem 5rem "

# Strip /* ... */ comments (multi-line aware) so commented-out examples and
# prose mentioning a hex value don't false-positive.
strip_comments() {
  awk '
  {
    line = $0; out = ""
    while (length(line) > 0) {
      if (incomment) {
        p = index(line, "*/")
        if (p == 0) { line = ""; break }
        line = substr(line, p + 2); incomment = 0
      } else {
        p = index(line, "/*")
        if (p == 0) { out = out line; break }
        out = out substr(line, 1, p - 1)
        line = substr(line, p + 2); incomment = 1
      }
    }
    print out
  }'
}

# Emit "<label>:<text>" for each declaration of the given property found in
# comment-stripped CSS on stdin.
extract_decls() {
  # $1 = property name
  grep -oE "$1[[:space:]]*:[[:space:]]*[^;}]*" || true
}

decl_value() {
  # strip "prop:" prefix and surrounding whitespace
  sed -E 's/^[a-z-]+[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//'
}

# ── Per-source scan ─────────────────────────────────────────────────────────
# check_source <label> reads comment-stripped CSS on stdin and appends
# violations to the three accumulator variables.
hex_violations=""
font_violations=""
radius_violations=""
spacing_violations=""

COLOUR_LITERAL='#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\('

check_source() {
  local label="$1" css
  css="$(cat)"

  # 1. colour placement: literals allowed only on custom-property declaration
  #    lines in Public/*.css.  Leaf <style> blocks may not contain any.
  local hexes
  if [[ "$label" == Public/*.css ]]; then
    hexes="$(printf '%s\n' "$css" \
      | grep -nE "$COLOUR_LITERAL" \
      | grep -vE '^[0-9]+:[[:space:]]*--[A-Za-z0-9_-]+[[:space:]]*:' || true)"
  else
    hexes="$(printf '%s\n' "$css" | grep -nE "$COLOUR_LITERAL" || true)"
  fi
  if [ -n "$hexes" ]; then
    while IFS= read -r hit; do
      hex_violations+="  ${label}: ${hit#*:}"$'\n'
    done <<< "$hexes"
  fi

  # 2. font-size values
  local v
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    case "$v" in
      "var(--text-"*) ;;
      inherit) ;;
      *rem) font_violations+="  ${label}: font-size: ${v}"$'\n' ;;
      *em) ;;                       # relative sizing, incl. e.g. "5em" (rem excluded above)
      *) font_violations+="  ${label}: font-size: ${v}"$'\n' ;;
    esac
  done < <(printf '%s\n' "$css" | extract_decls 'font-size' | decl_value)

  # 3. border-radius values
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    case "$v" in
      "var(--radius-"*) ;;
      0) ;;
      50%) ;;
      *" "*) ;;                     # multi-value corner shorthand
      *) radius_violations+="  ${label}: border-radius: ${v}"$'\n' ;;
    esac
  done < <(printf '%s\n' "$css" | extract_decls 'border-radius' | decl_value)

  # 4. spacing lattice: each rem component of padding/margin/gap must be an
  #    allowed step (leading zeros normalized; non-rem components ignored).
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    case "$SPACING_STEPS" in
      *" $v "*) ;;
      *) spacing_violations+="  ${label}: spacing step ${v}"$'\n' ;;
    esac
  done < <(printf '%s\n' "$css" \
    | extract_decls '(padding|margin|gap)[a-z-]*' \
    | decl_value \
    | tr ' ' '\n' \
    | grep -E '^-?0?\.?[0-9][0-9.]*rem$' \
    | sed 's/^0\./\./; s/^-0\./-./' \
    | sort -u)
}

# check_source must run in THIS shell (not a pipeline subshell) so the
# accumulator variables survive — hence process substitution, not a pipe.
for f in "${css_files[@]}"; do
  check_source "$f" < <(strip_comments < "$f")
done

for f in "${views[@]}"; do
  check_source "$f" < <(sed -n '/<style>/,/<\/style>/p' "$f" | strip_comments)
done

if [ -n "$hex_violations" ]; then
  status=1
  echo "ERROR: raw colour literal (#hex / rgb / rgba / hsl) outside the palette."
  echo "       Colour literals are allowed only as --token declarations in"
  echo "       Public/styles.css.  Use an existing var(--x), or add a semantic"
  echo "       token (with a dark-mode value) to the palette."
  printf '%s' "$hex_violations"
  echo
fi

if [ -n "$font_violations" ]; then
  status=1
  echo "ERROR: font-size does not use the type scale."
  echo "       Use var(--text-2xs|xs|sm|base|md|lg|xl|2xl) — pick the nearest"
  echo "       step (see docs/ui-design.md); em/inherit are allowed for"
  echo "       relative sizing inside a component."
  printf '%s' "$font_violations"
  echo
fi

if [ -n "$radius_violations" ]; then
  status=1
  echo "ERROR: border-radius does not use the radius scale."
  echo "       Use var(--radius-sm|md|lg|full); 0, 50%, and multi-value corner"
  echo "       shorthands are allowed."
  printf '%s' "$radius_violations"
  echo
fi

if [ -n "$spacing_violations" ]; then
  status=1
  echo "ERROR: padding/margin/gap uses a rem value off the spacing lattice."
  echo "       Pick the nearest existing step (preferred steps for new code"
  echo "       are in docs/ui-design.md; the full lattice is SPACING_STEPS in"
  echo "       this script).  Do not add a new step for a one-off."
  printf '%s' "$spacing_violations"
  echo
fi

if [ "$status" -eq 0 ]; then
  echo "check-design-tokens: OK (palette-only colours; type/radius/spacing scales in use)"
fi

exit "$status"

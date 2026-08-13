#!/usr/bin/env bash
set -euo pipefail

# Maintenance-page palette sync check (invoked from check-styles.sh).
#
# deploy/error-pages/maintenance.html is served by nginx when the app is down,
# so it must be completely self-contained — it cannot link styles.css and has
# to restate its colours inline. That restatement is the one place app colours
# exist OUTSIDE the guarded Public/*.css + template scope, and it drifted
# exactly as predicted: the page shipped a body background and text colour
# that matched nothing in the palette, plus a token named --border bound to a
# different value than the app's --border resolves to.
#
# The invariant enforced here is SUBSET, not equality of names: every colour
# literal in the maintenance page (rule bodies, custom properties, inline SVG
# fills) must byte-equal (case/whitespace-insensitively) some literal that
# appears in Public/styles.css. Renaming the page's local custom properties is
# fine; inventing a colour the app palette does not contain is not. When
# styles.css changes a colour, the stale copy here stops matching and this
# check names it.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

page="deploy/error-pages/maintenance.html"
sheet="Public/styles.css"

COLOUR_LITERAL='#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)|hsla?\([^)]*\)'

# Normalize a stream of colour literals: lowercase, strip all whitespace.
normalize() {
  tr -d ' \t' | tr '[:upper:]' '[:lower:]' | sort -u
}

# Strip block comments so prose mentioning a colour cannot false-positive.
strip_comments() {
  sed -E 's#/\*[^*]*\*+([^/*][^*]*\*+)*/##g; s#<!--([^-]|-[^-])*-->##g'
}

palette="$(strip_comments < "$sheet" | grep -oE "$COLOUR_LITERAL" | normalize)"
page_colours="$(strip_comments < "$page" | grep -oE "$COLOUR_LITERAL" | normalize)"

status=0
missing=""
while IFS= read -r c; do
  [ -z "$c" ] && continue
  if ! printf '%s\n' "$palette" | grep -qxF -- "$c"; then
    missing+="  ${c}"$'\n'
  fi
done <<< "$page_colours"

if [ -n "$missing" ]; then
  status=1
  echo "ERROR: ${page} uses a colour that does not exist in ${sheet}."
  echo "       The maintenance page mirrors the app palette by value (it cannot"
  echo "       link the stylesheet). Update the copy to the palette's current"
  echo "       value, or add the colour to the palette first."
  printf '%s' "$missing"
  echo
fi

if [ "$status" -eq 0 ]; then
  count="$(printf '%s\n' "$page_colours" | grep -c . || true)"
  echo "check-maintenance-palette: OK (${count} colour literals, all present in styles.css)"
fi

exit "$status"

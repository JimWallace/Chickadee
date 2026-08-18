#!/usr/bin/env bash
set -euo pipefail

# UI vocabulary guard (pure grep/sed/awk — runs in the Swift CI container
# alongside the other format-lint steps; invoked from check-styles.sh).
#
# The token guards (check-design-tokens.sh, check-css-vars.sh) prove a value
# routes through the palette.  check-class-resolution.sh proves a name has a
# rule.  Guard 4 in check-styles.sh proves two selectors are not literally the
# same text.  None of them can see the layer above: a SECOND way to say
# something the vocabulary already says.
#
# That layer had exactly one source of pressure — PAGE_STYLE_BASELINE, which
# makes a page-local re-implementation expensive — and it has a hole the width
# of the global sheet: a new component costs nothing if you put it in
# Public/styles.css, which carries no budget at all.  Everything below is what
# went through that hole, generalized.  Three rules:
#
#   1. CATALOG.  A class with a rule in the global sheet should be named in
#      the component vocabulary in docs/ui-design.md.  That rule is already
#      written there ("a genuinely new pattern must be ADDED to it (and to
#      this list) rather than approximated privately") and was already
#      drifting — thirteen shipped components had never been added.  This is
#      a shrink-only ratchet, not an absolute: the point is not to document
#      every historical name, it is that the NEXT one costs a catalog entry,
#      paid in the PR that adds it, where review sees the new component next
#      to the one it would duplicate.
#
#   2. AFFORDANCES.  A closed allowlist of the property values that tell a
#      user what an element DOES — the pointer over a target, the dotted
#      underline promising a definition.  Guard 4c in check-styles.sh is a
#      blocklist of idioms already consolidated, so it can only ever catch a
#      repeat; this is the same idea pointed forwards.  A value outside the
#      list is a new interaction idiom, and adding one should be a decision
#      with a paragraph behind it rather than a line in a rule body.
#
#   3. HOVER PROSE.  A title attribute is a hover-only, touch-hostile,
#      unsearchable, screen-reader-inconsistent channel.  It holds a phrase.
#      When it holds sentences, the sentences belong on the page or in the
#      docs, and the guard's job is to make that trade visible at the moment
#      it is made.
#
# Scope: Public/styles.css + Resources/Views/*.leaf.  Rule 2 also reads page
# <style> blocks, since an idiom hides just as well in one.
#
# The three of these together would have failed the change that prompted
# them; see docs/ui-design.md "Interaction idioms" and "UI copy".

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sheet="Public/styles.css"
rulebook="docs/ui-design.md"
status=0

# ── 1. Component catalog ─────────────────────────────────────────────────────
#
# Shrink-only.  Lower it in the PR that earns it; headroom left behind gets
# spent by the next person adding a copy.
CATALOG_BASELINE=298

# Comment stripper.  A scanner cannot tell a selector from prose about a
# selector, and this codebase has been bitten by that three times (the
# handoff doc's rule 5).  It must span lines: the sheet's comments run to
# paragraphs, and a line-at-a-time strip leaves every line but the first,
# which is how a version string in prose first registered as a class here.
strip_css_comments() {
  awk '
    {
      line = $0; out = ""
      while (length(line)) {
        if (incomment) {
          p = index(line, "*/")
          if (p == 0) { line = "" } else { line = substr(line, p + 2); incomment = 0 }
        } else {
          p = index(line, "/*")
          if (p == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, p - 1); line = substr(line, p + 2); incomment = 1 }
        }
      }
      print out
    }
  ' "$1"
}

# Classes carrying a rule in the global sheet.
sheet_classes="$(
  strip_css_comments "$sheet" \
    | tr '}' '\n' \
    | sed 's/{.*$//' \
    | grep -oE '\.[a-zA-Z][A-Za-z0-9_-]*' \
    | sed 's/^\.//' \
    | grep -vE '^js-' \
    | sort -u
)"

# Names the rulebook accounts for, either exactly or as a documented family
# (a tier-* entry covers every tier variant).  The catalog writes a class both
# with and without its leading dot, and sometimes several to a span (a class
# ORDER is quoted as one run of names), so every identifier-shaped token
# inside backticks counts.  That over-matches slightly — an attribute name in
# backticks can collide with a class name — and it errs in the safe direction:
# a spurious match understates the count, which only ever makes the ratchet
# stricter for the next change.
doc_tokens="$(
  grep -oE '`[^`]+`' "$rulebook" \
    | tr -d '`' | tr ' ' '\n' \
    | sed -e 's/^\.//' -e 's/[,;:()]*$//' \
    | grep -E '^[a-zA-Z][A-Za-z0-9_-]*(-\*)?$' \
    | sort -u || true
)"
doc_names="$(grep -v -- '-\*$' <<<"$doc_tokens" || true)"
doc_families="$(grep -- '-\*$' <<<"$doc_tokens" | sed 's/-\*$//' || true)"

undocumented="$(
  awk -v names="$doc_names" -v fams="$doc_families" '
    BEGIN {
      n = split(names, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") known[a[i]] = 1
      m = split(fams,  b, "\n"); for (i = 1; i <= m; i++) if (b[i] != "") family[++fc] = b[i]
    }
    {
      if ($0 in known) next
      for (i = 1; i <= fc; i++) if (index($0, family[i] "-") == 1) next
      print
    }
  ' <<<"$sheet_classes"
)"

catalog_count="$(printf '%s' "$undocumented" | grep -c . || true)"

if [ "$catalog_count" -gt "$CATALOG_BASELINE" ]; then
  status=1
  echo "ERROR: the global stylesheet grew a component the rulebook does not name."
  echo "       Undocumented classes in $sheet: $catalog_count (baseline $CATALOG_BASELINE)."
  echo
  echo "       A new component in the global sheet is currently free — the page-style"
  echo "       ratchet only prices a page-local one. This is that price. Either add the"
  echo "       new name to the component vocabulary in $rulebook (and check, while you"
  echo "       are there, that it is not a second spelling of something already in the"
  echo "       catalog), or reuse what is there."
  echo
  echo "       Undocumented names, for the diff:"
  printf '%s\n' "$undocumented" | sed 's/^/  /'
  echo
elif [ "$catalog_count" -lt "$CATALOG_BASELINE" ]; then
  status=1
  echo "ERROR: undocumented-component count dropped to $catalog_count (baseline $CATALOG_BASELINE)."
  echo "       Lower CATALOG_BASELINE in scripts/check-ui-vocabulary.sh to $catalog_count"
  echo "       in this PR — headroom left behind gets spent by the next copy."
  echo
fi

# ── 2. Affordance registry ───────────────────────────────────────────────────
#
# Each entry is an interaction the UI already makes. Extending this list is
# allowed and sometimes right — but it is a rulebook edit, not a CSS edit, so
# that the question "does this UI need a fifth way to signal something?" gets
# asked out loud. Keep in sync with the registry in docs/ui-design.md.
CURSOR_REGISTRY="pointer not-allowed grab grabbing default col-resize"
TEXT_DECORATION_REGISTRY="none underline line-through"

style_sources=("$sheet")
while IFS= read -r f; do style_sources+=("$f"); done < <(ls Resources/Views/*.leaf 2>/dev/null || true)

check_affordance() {
  local prop="$1" registry="$2" label="$3"
  local found
  found="$(
    grep -nE "(^|[;{[:space:]])${prop}[[:space:]]*:" "${style_sources[@]}" 2>/dev/null \
      | grep -v '^\s*/\*' \
      | sed -E "s/^([^:]+:[0-9]+):.*${prop}[[:space:]]*:[[:space:]]*([^;}!]*).*/\1|\2/" \
      | sed -E 's/[[:space:]]+$//' \
      | awk -F'|' -v reg="$registry" '
          BEGIN { n = split(reg, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
          { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); if (!(v in ok) && v != "") print $1 "  " v }
        ' || true
  )"
  if [ -n "$found" ]; then
    status=1
    echo "ERROR: unregistered $label affordance."
    echo "       Registered values: $registry"
    printf '%s\n' "$found" | sed 's/^/  /'
    echo
    echo "       A value outside the registry is a new way of telling a user what an"
    echo "       element does. If the UI genuinely needs one, add it to the registry in"
    echo "       $rulebook and to this script in the same PR, with the reasoning in the"
    echo "       PR description. If it does not, reuse the affordance already in use."
    echo
  fi
}

check_affordance "cursor" "$CURSOR_REGISTRY" "cursor"
check_affordance "text-decoration" "$TEXT_DECORATION_REGISTRY" "text-decoration"

# ── 3. Hover prose budget ────────────────────────────────────────────────────
#
# A phrase, not a paragraph. The cap is deliberately generous — it is a
# backstop against sentences accumulating in a tooltip, not a style opinion
# about any particular string.
TITLE_WORD_CAP=20

long_titles="$(
  awk -v cap="$TITLE_WORD_CAP" '
    FNR == 1 { inscript = 0 }
    /<script/ { inscript = 1 } /<\/script>/ { inscript = 0 }
    inscript { next }
    {
      line = $0
      while (match(line, /title="[^"]*"/)) {
        t = substr(line, RSTART + 7, RLENGTH - 8)
        line = substr(line, RSTART + RLENGTH)
        # Leaf interpolation renders to unknown length; the budget is on the
        # prose an author wrote, so a value-bearing title is out of scope.
        if (t ~ /#\(/) continue
        n = split(t, w, /[ \t]+/)
        words = 0
        for (i = 1; i <= n; i++) if (w[i] != "") words++
        if (words > cap) printf "%s:%d  (%d words)  %s\n", FILENAME, FNR, words, t
      }
    }
  ' Resources/Views/*.leaf 2>/dev/null || true
)"

if [ -n "$long_titles" ]; then
  status=1
  echo "ERROR: hover text over $TITLE_WORD_CAP words."
  printf '%s\n' "$long_titles" | sed 's/^/  /'
  echo
  echo "       A title attribute is hover-only: no touch device shows it, no search"
  echo "       finds it, and screen readers treat it inconsistently. It can hold a"
  echo "       phrase. Anything a reader must have belongs in the page — a note under"
  echo "       the control, a docs link — and anything they must not have can go."
  echo
fi

if [ "$status" -eq 0 ]; then
  echo "check-ui-vocabulary: OK (catalog at $catalog_count/$CATALOG_BASELINE; affordances registered; hover text within $TITLE_WORD_CAP words)"
fi

exit "$status"

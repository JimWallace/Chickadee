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
CATALOG_BASELINE=262

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

# The names a refusal can honestly redirect to: documented in the catalog AND
# carrying a rule in the sheet.  The catalog's backtick scan over-matches by
# design (rule 1's comment), so an attribute name quoted in prose — `title`,
# `hidden`, `cursor` — is in doc_names without being a component.  Suggesting
# one of those is worse than suggesting nothing: it sends an author to a class
# that does not exist.
catalog_components="$(
  comm -12 <(printf '%s\n' "$doc_names" | sort -u) <(printf '%s\n' "$sheet_classes" | sort -u)
)"

# Undocumented names that CONTAIN a catalog component's name, whole word for
# whole word — `estimate-chip` against `chip`.  Widest match first: a two-word
# catalog name found inside a three-word new one says more than one shared word
# does.
#
# Two exclusions, both of which are the CORRECT pattern rather than a duplicate,
# and both of which drowned the real hits when this first ran (37 rows, of which
# roughly ten were duplicates):
#
#   * A BEM modifier (`field-note--muted`) is a variant of its own base, not a
#     second spelling of it.  Any name carrying `--` is skipped outright.
#   * A name that EXTENDS a component in order (`standin-panel-title`,
#     `ext-panel-actions`) is a sub-part of it.  A duplicate reaches for the
#     component's noun and puts its own word in front — `estimate-chip`, not
#     `chip-estimate` — so a suggestion matching as an ordered prefix is
#     dropped and one matching anywhere else is kept.  That asymmetry is also
#     what stops `form-input--inline` being answered with `inline-form`.
#
# This finds the easy half of the problem and cannot find the other half.  A
# duplicate usually arrives under a name sharing nothing with its twin — that is
# how a pair of chips shipped as `.dataset-estimate-*` past every guard — so
# silence here is not evidence, and the message says so rather than implying the
# check was thorough.
near_catalog_names() {
  awk -v cat="$catalog_components" '
    BEGIN {
      n = split(cat, a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") { comp[++cn] = a[i]; ctok[cn] = split(a[i], t, "-") }
    }
    {
      name = $0
      if (name == "" || index(name, "--")) next
      np = split(name, part, "-")
      delete have
      for (x = 1; x <= np; x++) have[part[x]] = 1
      hits = ""; found = 0
      for (want = 4; want >= 1 && found < 3; want--) {
        for (i = 1; i <= cn && found < 3; i++) {
          if (ctok[i] != want) continue
          d = comp[i]
          if (length(d) < 4) continue
          nd = split(d, dp, "-")
          if (nd >= np) continue
          ok = 1
          for (y = 1; y <= nd; y++) if (!(dp[y] in have)) { ok = 0; break }
          if (!ok) continue
          prefix = 1
          for (y = 1; y <= nd; y++) if (dp[y] != part[y]) { prefix = 0; break }
          if (prefix) continue
          hits = hits (found++ ? ", " : "") d
        }
      }
      if (found) printf "  %-36s looks like  %s\n", name, hits
    }
  ' <<<"$1"
}

if [ "$catalog_count" -gt "$CATALOG_BASELINE" ]; then
  status=1
  echo "ERROR: the global stylesheet grew a component the rulebook does not name."
  echo "       Undocumented classes in $sheet: $catalog_count (baseline $CATALOG_BASELINE)."
  echo
  echo "       A new component in the global sheet is currently free — the page-style"
  echo "       ratchet only prices a page-local one. This is that price, and there are"
  echo "       two ways to pay it:"
  echo
  echo "       (a) It is a second spelling of something the UI already has. Delete it and"
  echo "           use the existing component. The count falls back on its own."
  echo "       (b) It is genuinely new. Add a bullet for it to the component vocabulary in"
  echo "           $rulebook, beside the component it sits closest to. Naming it is"
  echo "           what pays for it; the count falls back on its own then too."
  echo
  # The ratchet stores a count, not a list, so this cannot say WHICH name is
  # new — only that one is. Hence "find the one you added" rather than a filter.
  suggestions="$(near_catalog_names "$undocumented")"
  if [ -n "$suggestions" ]; then
    echo "       Names here are built out of a catalog component's own name. Find the one"
    echo "       you just added — it is the cheapest (a) to check. Most of the rest predate"
    echo "       your change, and a real duplicate looks exactly like them:"
    printf '%s\n' "$suggestions"
    echo
  fi
  echo "       Not finding yours above is not evidence. A second spelling usually arrives"
  echo "       under a name sharing no word with its twin, so search the catalog for the"
  echo "       CONCEPT — 'a short labelled value beside a control', 'a row of action"
  echo "       buttons' — rather than for the word you happened to choose."
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
# Each entry is an interaction the UI already makes, written `value:what it
# already says`. Extending this list is allowed and sometimes right — but it is
# a rulebook edit, not a CSS edit, so that the question "does this UI need a
# fifth way to signal something?" gets asked out loud. Keep in sync with the
# registry in docs/ui-design.md.
#
# The meanings are carried here, not just the values, so a refusal can name what
# the registered values ALREADY say. "Reuse the affordance already in use" is not
# actionable when the reader does not know which one covers their case; a list of
# meanings is a redirect, a list of values is only a smaller no.
CURSOR_REGISTRY="pointer:activates something
not-allowed:this control is disabled
grab:this can be dragged to reorder
grabbing:it is being dragged right now
col-resize:this edge resizes a pane
default:deliberately not interactive, despite looking so"
TEXT_DECORATION_REGISTRY="underline:a link, or a word carrying a definition
line-through:a superseded value
none:strip an underline the browser added"

style_sources=("$sheet")
while IFS= read -r f; do style_sources+=("$f"); done < <(ls Resources/Views/*.leaf 2>/dev/null || true)

check_affordance() {
  local prop="$1" registry="$2" label="$3" hint="$4"
  local values found
  values="$(cut -d: -f1 <<<"$registry" | tr '\n' ' ')"
  found="$(
    grep -nE "(^|[;{[:space:]])${prop}[[:space:]]*:" "${style_sources[@]}" 2>/dev/null \
      | grep -v '^\s*/\*' \
      | sed -E "s/^([^:]+:[0-9]+):.*${prop}[[:space:]]*:[[:space:]]*([^;}!]*).*/\1|\2/" \
      | sed -E 's/[[:space:]]+$//' \
      | awk -F'|' -v reg="$values" '
          BEGIN { n = split(reg, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
          { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); if (!(v in ok) && v != "") print $1 "  " v }
        ' || true
  )"
  if [ -n "$found" ]; then
    status=1
    echo "ERROR: unregistered $label affordance."
    printf '%s\n' "$found" | sed 's/^/  /'
    echo
    echo "       A value outside the registry is a new way of telling a user what an"
    echo "       element does. These are the ways this UI already says one, and one of"
    echo "       them probably covers the case:"
    echo
    sed 's/^\([^:]*\):/  \1 — /' <<<"$registry"
    echo
    printf '%s\n' "$hint"
    echo
    echo "       If the UI genuinely needs a new value, add it to the registry in $rulebook"
    echo "       and to this script in the same PR, with the reasoning in the PR description."
    echo
  fi
}

# The closing advice is per property, because the two are not the same question.
# A new cursor is nearly always a new way to reveal something, so the reveal
# ladder is the right thing to read first; a new text-decoration is a new meaning
# for a line through text, and the ladder has nothing to say about it. One
# paragraph generalised across both read as a non-sequitur under the shorter list.
check_affordance "cursor" "$CURSOR_REGISTRY" "cursor" \
  "       A new cursor is nearly always a fifth way to reveal something the four
       idioms in $rulebook (\"Interaction idioms\", ordered cheapest-first)
       already reveal. Read that table before adding one."
check_affordance "text-decoration" "$TEXT_DECORATION_REGISTRY" "text-decoration" \
  "       An underline means a link; a line through means superseded. A third
       meaning for a line drawn on text is a convention every reader then has
       to learn, and it will not be visible as one to the person adding it."

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
  echo "       phrase, and anything a reader must have belongs somewhere they will"
  echo "       actually get it. Cheaper places to put it, roughly in order — the full"
  echo "       ladder, and the modal that ends it, are in $rulebook:"
  echo
  # Abridged on purpose (the modal rung is never the answer to "this tooltip is
  # too long"), so this does not claim to be the table. Keep in sync with the
  # "Interaction idioms" ladder there, as the affordance registry above does.
  echo "         they should just see it        a .chip for a value, .field-note under a"
  echo "                                        control, .card-meta under a title"
  echo "         they want it occasionally      a details element + .accordion-caret,"
  echo "                                        closed by default"
  echo "         it is about one row            .ext-details/.ext-panel, or .popover-panel"
  echo "         it is longer than a paragraph  docs/, and a link to it from the page"
  echo
  echo "       And some of it can simply go — a tooltip nobody can reach is not load-"
  echo "       bearing, whatever it says."
  echo
fi

if [ "$status" -eq 0 ]; then
  echo "check-ui-vocabulary: OK (catalog at $catalog_count/$CATALOG_BASELINE; affordances registered; hover text within $TITLE_WORD_CAP words)"
fi

exit "$status"

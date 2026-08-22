#!/usr/bin/env bash
set -euo pipefail

# View / stylesheet hygiene guard, wired into the format-lint CI job.
#
# Locks in the v0.4.x UI-cleanup invariants.  None of these are caught by the
# render tests — a stray inline style or an undefined CSS var renders fine and
# passes every test — so they need a static guard.  The convention:
#
#   * Shared styling lives in Public/styles.css; page-unique styling lives in a
#     page-local <style> block with role-named classes.
#   * No inline style="" in templates EXCEPT a JS-toggled `display:none` initial
#     state or a CSS custom-property assignment (e.g. style="--wb-left-width:42%").
#   * No new native alert() in templates or first-party Public/*.js — use the
#     inline .form-error pattern.
#   * Every var(--x) resolves, and no var(--x, #hex) colour fallbacks (see
#     scripts/check-css-vars.sh).
#   * Colours route through the palette (hex only in --token declarations),
#     and font-size / border-radius use the --text-* / --radius-* scales
#     (see scripts/check-design-tokens.sh and docs/ui-design.md).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

views=(Resources/Views/*.leaf)
status=0

# ── 1. CSS custom-property guard ────────────────────────────────────────────
scripts/check-css-vars.sh || status=1

# ── 1b. Design-token guard (palette-only hex, type + radius scales) ─────────
scripts/check-design-tokens.sh || status=1

# ── 1c. Maintenance-page palette sync ────────────────────────────────────────
scripts/check-maintenance-palette.sh || status=1

# ── 2. Inline-style allowlist ───────────────────────────────────────────────
# A style="" attribute is allowed only if every ;-separated declaration is
# `display:none` or a `--custom-prop:` assignment.  Anything else (margins,
# colours, flex, …) belongs in a semantic class.
inline_violations=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  # hit = path:line:style="..."
  value="$(printf '%s' "$hit" | sed -E 's/.*style="([^"]*)".*/\1/')"
  ok=1
  IFS=';' read -ra decls <<< "$value"
  for decl in "${decls[@]}"; do
    d="$(printf '%s' "$decl" | tr -d '[:space:]')"
    [ -z "$d" ] && continue
    case "$d" in
      display:none) ;;
      --*:*) ;;            # CSS custom-property assignment
      *) ok=0 ;;
    esac
  done
  [ "$ok" -eq 0 ] && inline_violations+="  ${hit}"$'\n'
done < <(grep -rno 'style="[^"]*"' "${views[@]}" || true)

if [ -n "$inline_violations" ]; then
  status=1
  echo "ERROR: disallowed inline style=\"\" in a template."
  echo "       Move it to a semantic CSS class.  Inline styles are permitted"
  echo "       only for a JS-toggled display:none or a --custom-prop assignment."
  printf '%s' "$inline_violations"
  echo
fi

# ── 3. No new native alert() in templates ───────────────────────────────────
# At ZERO as of the S9 feedback-channel consolidation: every blocking error
# now uses the inline .form-error banner (ChickadeeUI.showActionError). The
# baseline may only go DOWN, so from here the rule is absolute.
ALERT_BASELINE=0
alert_count="$( { grep -rho 'alert(' "${views[@]}" || true; } | wc -l | tr -d ' ')"
if [ "$alert_count" -gt "$ALERT_BASELINE" ]; then
  status=1
  echo "ERROR: new native alert() in a template (found ${alert_count}, baseline ${ALERT_BASELINE})."
  echo "       Surface errors with the inline .form-error pattern instead."
  grep -rn 'alert(' "${views[@]}" | sed 's/^/  /'
  echo
elif [ "$alert_count" -lt "$ALERT_BASELINE" ]; then
  echo "note: alert() count dropped to ${alert_count}; lower ALERT_BASELINE in scripts/check-styles.sh."
fi

# ── 3a. No new native alert() in first-party JS ─────────────────────────────
# Same rule, same direction, for Public/*.js.  The template ratchet alone was
# leaky: the inline-script ratchet (3b) pushes page JS out into Public/*.js,
# which the template glob never sees — so an alert() could be laundered out of
# scope by the very move 3b encourages.  Top-level Public/*.js only; the
# vendored/generated trees (Public/pyodide, Public/jupyterlite, Public/vendor,
# Public/runner-wasm) are not ours to lint.  Also at ZERO as of S9.
JS_ALERT_BASELINE=0
js_alert_count="$( { grep -ho 'alert(' Public/*.js || true; } | wc -l | tr -d ' ')"
if [ "$js_alert_count" -gt "$JS_ALERT_BASELINE" ]; then
  status=1
  echo "ERROR: new native alert() in first-party JS (found ${js_alert_count}, baseline ${JS_ALERT_BASELINE})."
  echo "       Surface errors with the inline .form-error pattern instead."
  grep -n 'alert(' Public/*.js | sed 's/^/  /'
  echo
elif [ "$js_alert_count" -lt "$JS_ALERT_BASELINE" ]; then
  echo "note: JS alert() count dropped to ${js_alert_count}; lower JS_ALERT_BASELINE in scripts/check-styles.sh."
fi

# ── 3b. Inline <script> is closed (#1135; conversion completed 2026-08) ──────
# JS inside a template <script> block is invisible to every tool — ESLint
# can't parse Leaf-interpolated JS, CodeQL skips it, node --check can't run
# it.  Page behaviour lives in Public/*.js files (loaded with <script src>);
# a template carries data via data-* attributes or a single-line JSON island.
# The 2026-08 pass externalized every page's blocks, so what was a
# total-line ratchet is now an absolute rule: no template may open a
# multi-line <script> body — except base.leaf, whose multipart-CSRF
# interceptor is the one deliberate holdout (docs/ui-ratchet-handoff.md);
# that block is held by its own shrink-only line ratchet below.
# <script src=…> includes and single-line <script …>…</script> elements
# (the JSON seed islands) don't count.
INLINE_SCRIPT_ALLOWED_FILE="Resources/Views/base.leaf"
INLINE_SCRIPT_BASELINE=74
count_inline_script() {
  # Non-blank lines inside multi-line <script> bodies.  A single-line
  # element must match on "<script" (not "<script>"): the JSON islands carry
  # id/type attributes, and treating them as block openers leaks the
  # in-script state across the rest of the file.
  awk '
    /<script[^>]*src=/ { next }
    /<script/ && /<\/script>/ { next }
    /<script/ { inscript = 1; next }
    /<\/script>/ { inscript = 0; next }
    inscript && NF > 0 { n++ }
    END { print n + 0 }
  ' "$1"
}
inline_script_offenders=""
for f in "${views[@]}"; do
  [ "$f" = "$INLINE_SCRIPT_ALLOWED_FILE" ] && continue
  n="$(count_inline_script "$f")"
  [ "$n" -gt 0 ] && inline_script_offenders+="  ${f} (${n} lines)"$'\n'
done
if [ -n "$inline_script_offenders" ]; then
  status=1
  echo "ERROR: multi-line inline <script> in a template."
  echo "       Put page JS in a Public/*.js file (loaded with <script src>) so it"
  echo "       is linted and testable; pass page data via data-* attributes or a"
  echo "       single-line JSON island.  See docs/ui-design.md."
  printf '%s' "$inline_script_offenders"
  echo
fi
base_inline_count="$(count_inline_script "$INLINE_SCRIPT_ALLOWED_FILE")"
if [ "$base_inline_count" -gt "$INLINE_SCRIPT_BASELINE" ]; then
  status=1
  echo "ERROR: base.leaf's inline <script> grew (${base_inline_count} lines, baseline ${INLINE_SCRIPT_BASELINE})."
  echo "       New behaviour belongs in a Public/*.js file, base.leaf included."
elif [ "$base_inline_count" -lt "$INLINE_SCRIPT_BASELINE" ]; then
  echo "note: base.leaf's inline <script> dropped to ${base_inline_count}; lower INLINE_SCRIPT_BASELINE in scripts/check-styles.sh."
fi

# ── 3c. JS styling-decision ratchet ─────────────────────────────────────────
# Styling written by JavaScript is invisible to every CSS guard above: the
# audit found the type and radius scales 100% bypassed in JS (11 font-size
# literals, none a token), an injected stylesheet with its own dark-mode
# block, and spacing values that would fail rule 4 verbatim in a .css file.
# Counted here: style="…" inside generated-HTML strings, .style.<prop>
# writes (display toggles exempt — show/hide is behaviour, not styling),
# and cssText. Baseline may only go DOWN. The rule for new code
# (docs/ui-design.md): JS toggles classes or sets a custom property
# (workbench.js's --wb-left-width is the pattern); it does not decide
# styling.
JS_STYLE_DECISION_BASELINE=10
js_style_count="$(
  {
    grep -ho 'style="' Public/*.js || true
    grep -hoE '\.style\.[a-zA-Z]+' Public/*.js | grep -v '\.style\.display' || true
    grep -ho 'cssText' Public/*.js || true
  } | wc -l | tr -d ' '
)"
if [ "$js_style_count" -gt "$JS_STYLE_DECISION_BASELINE" ]; then
  status=1
  echo "ERROR: JS styling decisions grew (${js_style_count}, baseline ${JS_STYLE_DECISION_BASELINE})."
  echo "       New page styling belongs in a class in Public/styles.css; JS toggles"
  echo "       the class (or sets a --custom-property). See docs/ui-design.md."
elif [ "$js_style_count" -lt "$JS_STYLE_DECISION_BASELINE" ]; then
  echo "note: JS styling decisions dropped to ${js_style_count}; lower JS_STYLE_DECISION_BASELINE in scripts/check-styles.sh."
fi

# ── 3d. JS may not write colour or typography via .style — absolute ──────────
# The worst class of JS styling decision: a colour or type property written
# from script bypasses the palette (no dark-mode value — invisible-on-dark
# waiting to happen) and the type scale. The editors' validity cues were 30
# of these; all are toggled classes now (.input-invalid, .input-ref-ok, …,
# styles.css), and the count reached zero in one pass, so the rule is
# absolute rather than a ratchet. Writes only — a .style read stays legal.
s3d="$(grep -rnE '\.style\.(color|background|backgroundColor|borderColor|border|outline|boxShadow|fontStyle|fontSize|fontFamily|font|textDecoration)\s*=' Public/*.js || true)"
if [ -n "$s3d" ]; then
  status=1
  echo "ERROR: a colour/typography property written via .style in first-party JS."
  echo "       Toggle a class from Public/styles.css instead, so the value rides"
  echo "       the palette and the type scale (docs/ui-design.md)."
  printf '%s\n' "$s3d" | sed 's/^/  /'
  echo
fi

# ── 3e. style=\" in a JS-built HTML string must be custom-prop-only ──────────
# The same rule templates already live under (section 2): a style attribute
# inside a generated-HTML string may only assign CSS custom properties (e.g.
# the meter's --bar-h) or the JS-toggled display:none initial state. Anything
# else is a styling decision the CSS guards cannot see. The editors' row
# builders held ~50 of these; all are classes now, so the rule is absolute.
js_inline_violations=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  value="$(printf '%s' "$hit" | sed -E 's/.*style="([^"]*)".*/\1/')"
  ok=1
  IFS=';' read -ra decls <<< "$value"
  for decl in "${decls[@]}"; do
    d="$(printf '%s' "$decl" | tr -d '[:space:]')"
    [ -z "$d" ] && continue
    case "$d" in
      display:none) ;;
      --*:*) ;;            # CSS custom-property assignment
      *) ok=0 ;;
    esac
  done
  [ "$ok" -eq 0 ] && js_inline_violations+="  ${hit}"$'\n'
done < <(grep -rno 'style="[^"]*"' Public/*.js || true)

if [ -n "$js_inline_violations" ]; then
  status=1
  echo "ERROR: disallowed style=\"\" inside a JS-built HTML string."
  echo "       Use a class from Public/styles.css. A style attribute in generated"
  echo "       markup may only assign a --custom-prop or the display:none initial"
  echo "       state — the same rule templates follow."
  printf '%s' "$js_inline_violations"
  echo
fi

# ── 4. No duplicated / shadowed selectors in page <style> blocks ─────────────
# Page-local <style> blocks should only define page-unique classes.  Two
# regressions the cleanup removed (and that render fine, so no test catches):
#   A. a page block re-defines a selector that already lives in the global
#      sheet (e.g. submission.leaf shadowing the global .achievement-badge);
#   B. the same selector is defined in more than one page block (cross-page
#      duplication that should be hoisted to styles.css).
# `.main` is an allowlisted intentional global override (notebook.leaf narrows
# the page container).  Heuristic extractor: selector = text before each `{`
# (one selector per line, as authored here), skipping at-rules and comments —
# errs toward false negatives, never false positives.
ALLOW_GLOBAL_OVERRIDE="^\.main$"

extract_selectors() {
  # `|| true` on the greps so no-match (e.g. a file with no <style> block)
  # doesn't trip pipefail.
  sed -E 's#/\*.*\*/##g' \
    | { grep '{' || true; } \
    | sed -E 's/\{.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | { grep -vE '^$|^@|^/\*' || true; }
}

global_sel="$(extract_selectors < Public/styles.css | sort -u)"

# Build "selector<TAB>file" pairs from every page <style> block.
pairs="$(
  for f in "${views[@]}"; do
    base="$(basename "$f")"
    sed -n '/<style>/,/<\/style>/p' "$f" | extract_selectors \
      | while IFS= read -r sel; do [ -n "$sel" ] && printf '%s\t%s\n' "$sel" "$base"; done
  done | sort -u
)"

# A. page selector also declared globally (excluding the allowlist).
shadowed=""
while IFS=$'\t' read -r sel file; do
  [ -z "$sel" ] && continue
  if printf '%s\n' "$sel" | grep -qE "$ALLOW_GLOBAL_OVERRIDE"; then continue; fi
  if printf '%s\n' "$global_sel" | grep -qxF -- "$sel"; then
    shadowed+="  ${file}: ${sel}"$'\n'
  fi
done <<< "$pairs"

if [ -n "$shadowed" ]; then
  status=1
  echo "ERROR: a page <style> block re-defines a selector from the global sheet."
  echo "       Use the global rule, or rename the page-local class."
  printf '%s' "$shadowed"
  echo
fi

# B. same selector defined in more than one page block.
cross="$(printf '%s\n' "$pairs" | cut -f1 | sort | uniq -d)"
if [ -n "$cross" ]; then
  status=1
  echo "ERROR: the same selector is defined in more than one page <style> block."
  echo "       Hoist the shared rule into Public/styles.css (or rename if they differ)."
  while IFS= read -r sel; do
    [ -z "$sel" ] && continue
    files="$(printf '%s\n' "$pairs" | awk -F'\t' -v s="$sel" '$1==s{printf " %s", $2}')"
    echo "  ${sel} →${files}"
  done <<< "$cross"
  echo
fi

# ── 4b. Page <style> block size ratchet ─────────────────────────────────────
# Page-local CSS is the sanctioned escape hatch for genuinely page-unique
# styling — and it is where concept drift lives: the same visual idea
# re-implemented under a fresh local name, which guard 4 cannot see because
# the names never repeat. Economics instead of detection: the total may only
# shrink, so new styling must either be small and truly page-unique or land
# in Public/styles.css as a named component, where review sees it next to
# the component it would duplicate. When you shrink a block, lower the
# baseline in the same PR (same contract as INLINE_SCRIPT_BASELINE).
PAGE_STYLE_BASELINE=677
page_style_count="$(
  awk '
    FNR==1 { inblock = 0 }
    /<style>/ { inblock = 1; next }
    /<\/style>/ { inblock = 0; next }
    inblock && NF > 0 { n++ }
    END { print n + 0 }
  ' "${views[@]}"
)"
if [ "$page_style_count" -gt "$PAGE_STYLE_BASELINE" ]; then
  status=1
  echo "ERROR: page <style> blocks grew (${page_style_count} lines, baseline ${PAGE_STYLE_BASELINE})."
  echo "       Reuse a component from Public/styles.css (see docs/ui-design.md's"
  echo "       vocabulary), or hoist the new pattern there as a named component."
elif [ "$page_style_count" -lt "$PAGE_STYLE_BASELINE" ]; then
  echo "note: page <style> lines dropped to ${page_style_count}; lower PAGE_STYLE_BASELINE in scripts/check-styles.sh."
fi

# ── 4c. Consolidated widget idioms may not fork back (ui-consistency-audit) ─
# S1: live list filtering is Public/list-filter.js (input[data-list-filter]).
# The two idioms it replaced must not return: a page-local filter
# implementation in an inline script, or the readonly-until-focus autofill
# hack hand-carried in template markup (the component owns that suppression).
s1_hack="$(grep -rn "onfocus=\"this\.removeAttribute('readonly')\"" "${views[@]}" || true)"
s1_local="$(grep -rnE 'function apply[A-Za-z]*Filter' "${views[@]}" || true)"
if [ -n "${s1_hack}${s1_local}" ]; then
  status=1
  echo "ERROR: a page re-implements the shared list-filter idiom."
  echo "       Use input[data-list-filter] (Public/list-filter.js) — it owns"
  echo "       both the row matching and the autofill suppression."
  { [ -n "$s1_hack" ] && printf '%s\n' "$s1_hack"; [ -n "$s1_local" ] && printf '%s\n' "$s1_local"; } | sed 's/^/  /'
  echo
fi

# S1 (cont.): one control means one DRESS, not just one implementation. Five
# filter boxes shared list-filter.js and still came in three widths — two inline
# --filter-width values plus a page-local flex basis — because the property read
# as a per-page dial. It is declared once in styles.css (:root) and may not be
# re-assigned in a template.
#
# The rest of the contract (a .filter-group wrapper, type=search, no markup
# autocomplete, live-or-GET-form) is structural, so it is asserted by walking the
# tags in Tests/APITests/ListFilterMarkupTests.swift rather than counted here —
# a count is a weak proxy for containment, and this file's own rule is to parse
# structure rather than search the document.
# The rule generalizes past the filter, because the filter was the SECOND
# instance: --form-stack-width was a per-page dial too (60rem on the MCP tab,
# 32rem on slip days — 2rem off the default, for no reason anyone recorded).
# So an inline custom property may only carry a value that varies per DATUM,
# not per page. --bar-h is the honest case: a chart bar's height comes from the
# row the server is rendering and cannot live in a stylesheet. A width that
# differs because someone preferred it there is a design decision, and belongs
# in styles.css as the token's value or as a named modifier class.
# The avatar props are the second honest case, and the same shape as --bar-h:
# every one carries a palette token chosen for the STUDENT the server is
# rendering, so no stylesheet can hold it and no modifier class could enumerate
# 9,216 of them. They are a closed set — one per slot in AvatarSpec, plus the
# wing-mark that reuses the cheek — and the Swift side names the tokens
# (Core/AvatarMarkup.swift), so a page cannot invent an eighth.
PER_DATUM_INLINE_PROPS="--bar-h --av-cap --av-wing --av-accent --av-backdrop"
inline_prop_violations=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  name="$(printf '%s' "$hit" | sed -E 's/.*style="[[:space:]]*(--[A-Za-z0-9_-]+).*/\1/')"
  case " $PER_DATUM_INLINE_PROPS " in
    *" $name "*) ;;
    *) inline_prop_violations+="  ${hit}"$'\n' ;;
  esac
done < <(grep -rno 'style="--[^"]*"' "${views[@]}" || true)

if [ -n "$inline_prop_violations" ]; then
  status=1
  echo "ERROR: a template assigns a component custom property inline."
  echo "       A component's width is one decision, declared in styles.css"
  echo "       (:root), or a named modifier class there — never an inline"
  echo "       number, which no review reads and every page can differ on."
  echo "       Inline custom props are for per-DATUM values only (${PER_DATUM_INLINE_PROPS})."
  printf '%s' "$inline_prop_violations"
  echo
fi

# S2: column sorting is Public/sortable-table.js (.sortable-table +
# th > button.sort-header). The two dialects it replaced must not return: a
# page-local sort implementation, or a page-local sort affordance (the
# th[data-sort-key]::after glyph CSS, the .sort-icon span). A th that declares
# data-sort-type must carry the shared button, or it is decorative markup that
# sorts nothing.
s2_impl="$(grep -rnE 'function sort[A-Za-z]*(ByHeader|Rows|Array)' "${views[@]}" || true)"
s2_glyph="$(grep -rnE 'data-sort-key\]::after|class="sort-icon"' "${views[@]}" Public/*.css || true)"
s2_orphan="$(grep -rn 'data-sort-type' "${views[@]}" | grep -v 'sort-header' || true)"
if [ -n "${s2_impl}${s2_glyph}${s2_orphan}" ]; then
  status=1
  echo "ERROR: a page re-implements the shared sortable-table idiom."
  echo "       Use .sortable-table + <th data-sort-key data-sort-type>"
  echo "       <button class=\"sort-header\">, and Public/sortable-table.js's"
  echo "       apply() to restore the sort after a repaint."
  { [ -n "$s2_impl" ] && printf '%s\n' "$s2_impl"
    [ -n "$s2_glyph" ] && printf '%s\n' "$s2_glyph"
    [ -n "$s2_orphan" ] && printf '%s\n' "$s2_orphan"; } | sed 's/^/  /'
  echo
fi

# S4: drawn geometry lives in a sprite and is referenced by a use element.
# Raw path data anywhere else is a new copy of a shape that already exists —
# the trash can had fifteen, in three byte-level variants, which is how "change
# the delete icon" became a grep-and-pray.
#
# TWO files may hold geometry, for two different vocabularies: _icons.leaf is
# the stroked 24x24 Feather set inlined on every page, and _avatar-sprite.leaf
# is the flat-filled 64x64 chickadee parts, included only by pages that show an
# avatar. A third would want the same justification: a distinct vocabulary with
# a distinct set of pages, not just somewhere else to paste a path.
s4_svg="$(grep -rln '<path d=\|<polyline points=\|<circle cx=' "${views[@]}" Public/*.js \
  | grep -vE 'Resources/Views/(_icons|_avatar-sprite)\.leaf' || true)"
if [ -n "$s4_svg" ]; then
  status=1
  echo "ERROR: inline SVG geometry outside the icon sprite."
  echo "       Add a <symbol> to Resources/Views/_icons.leaf and reference it:"
  echo "       <svg class=\"icon\" aria-hidden=\"true\"><use href=\"#i-name\"/></svg>"
  printf '%s\n' "$s4_svg" | sed 's/^/  /'
  echo
fi

# S5: destructive confirmation is data-confirm (handled in app.js). An inline
# onclick/onsubmit confirm attribute is the idiom it replaced — 49 of them,
# with the same action worded differently on different pages. Keeping the
# question in markup is what made replacing the native dialog a one-place
# change, and that replacement has now happened: ChickadeeUI.confirmAction
# renders a real dialog, so the NATIVE call is at zero and the exemption this
# check used to carry for it is gone. The rule is now absolute, like the
# alert() ratchets above — the native dialog was the last piece of UI outside
# the design system, unthemed and invisible to the axe scan.
s5_inline="$(grep -rnE 'on(click|submit)="return (window\.)?confirm\(' "${views[@]}" || true)"
s5_raw="$(grep -rnE '(^|[^.\w])confirm\(' "${views[@]}" Public/*.js \
  | grep -v 'ChickadeeUI.confirmAction' || true)"
if [ -n "${s5_inline}${s5_raw}" ]; then
  status=1
  echo "ERROR: a native confirm() — the shared dialog is the only one."
  echo "       Declare the question in markup with data-confirm=\"…\", or await"
  echo "       ChickadeeUI.confirmAction(msg) where there is no element to mark."
  { [ -n "$s5_inline" ] && printf '%s\n' "$s5_inline"
    [ -n "$s5_raw" ] && printf '%s\n' "$s5_raw"; } | sed 's/^/  /'
  echo
fi

# S6: one size modifier per button component. `btn-tiny` and `action-btn-tight`
# were second sizes for jobs `btn-compact` and `action-btn-icon` already did —
# which is how one page ended up with two same-role "Save" buttons at different
# sizes. Retired names must not come back; check-class-resolution.sh catches a
# name with no rule, but not a name someone re-adds a rule for.
s6_retired="$(grep -rnE 'btn-tiny|action-btn-tight' "${views[@]}" Public/*.js Public/*.css || true)"
if [ -n "$s6_retired" ]; then
  status=1
  echo "ERROR: retired button size modifier."
  echo "       Buttons have two sizes: default and btn-compact (.btn), and"
  echo "       action-btn-icon is the one narrow variant of .action-btn."
  printf '%s\n' "$s6_retired" | sed 's/^/  /'
  echo
fi

# ── 5. Class names must resolve ──────────────────────────────────────────────
scripts/check-class-resolution.sh || status=1

# ── 6. The vocabulary above the token layer ──────────────────────────────────
# Guard 4 compares selector TEXT and guard 4b prices a page-local copy, so
# between them a second spelling of an existing component is free as long as
# it is spelled differently and lives in the global sheet. This prices that,
# plus the two things nothing else looks at: the affordances that tell a user
# an element is interactive, and how much prose a tooltip carries.
scripts/check-ui-vocabulary.sh || status=1

if [ "$status" -eq 0 ]; then
  echo "check-styles: OK (no disallowed inline styles; alert()s within baseline; no duplicated selectors; ratchets within baseline)"
fi

exit "$status"

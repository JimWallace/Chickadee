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
#     state or a CSS custom-property assignment (e.g. style="--filter-width:220px").
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
# Baseline = pre-existing alert()s (rare support-file error paths in the
# assignment editors).  This may only go DOWN; new alert()s must use the
# inline .form-error banner instead.
ALERT_BASELINE=4
alert_count="$(grep -rho 'alert(' "${views[@]}" | wc -l | tr -d ' ')"
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
# Public/runner-wasm) are not ours to lint.
JS_ALERT_BASELINE=7
js_alert_count="$(grep -ho 'alert(' Public/*.js | wc -l | tr -d ' ')"
if [ "$js_alert_count" -gt "$JS_ALERT_BASELINE" ]; then
  status=1
  echo "ERROR: new native alert() in first-party JS (found ${js_alert_count}, baseline ${JS_ALERT_BASELINE})."
  echo "       Surface errors with the inline .form-error pattern instead."
  grep -n 'alert(' Public/*.js | sed 's/^/  /'
  echo
elif [ "$js_alert_count" -lt "$JS_ALERT_BASELINE" ]; then
  echo "note: JS alert() count dropped to ${js_alert_count}; lower JS_ALERT_BASELINE in scripts/check-styles.sh."
fi

# ── 3b. Inline <script> line-count ratchet (#1135) ───────────────────────────
# JS inside a template <script> block is invisible to every tool — ESLint
# can't parse Leaf-interpolated JS, CodeQL skips it, node --check can't run
# it — and it's why the CSP still allows inline script.  New page behaviour
# belongs in a lintable Public/*.js file (template carries data via data-*
# attributes or a JSON island).  Baseline = total non-blank lines inside
# <script> bodies across all templates; it may only go DOWN.  <script src=…>
# includes and single-line <script>…</script> elements don't count.
INLINE_SCRIPT_BASELINE=1968
inline_script_count="$(
  awk '
    /<script[^>]*src=/ { next }
    /<script>/ && /<\/script>/ { next }
    /<script/ { inscript = 1; next }
    /<\/script>/ { inscript = 0; next }
    inscript && NF > 0 { n++ }
    END { print n + 0 }
  ' "${views[@]}"
)"
if [ "$inline_script_count" -gt "$INLINE_SCRIPT_BASELINE" ]; then
  status=1
  echo "ERROR: inline <script> grew (${inline_script_count} lines, baseline ${INLINE_SCRIPT_BASELINE})."
  echo "       Put new page JS in a Public/*.js file (loaded with <script src>)"
  echo "       so it is linted and testable; pass page data via data-* attributes"
  echo "       or a JSON island.  See docs/ui-design.md."
elif [ "$inline_script_count" -lt "$INLINE_SCRIPT_BASELINE" ]; then
  echo "note: inline <script> lines dropped to ${inline_script_count}; lower INLINE_SCRIPT_BASELINE in scripts/check-styles.sh."
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
JS_STYLE_DECISION_BASELINE=122
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
PAGE_STYLE_BASELINE=913
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

# ── 5. Class names must resolve ──────────────────────────────────────────────
scripts/check-class-resolution.sh || status=1

if [ "$status" -eq 0 ]; then
  echo "check-styles: OK (no disallowed inline styles; alert()s within baseline; no duplicated selectors; ratchets within baseline)"
fi

exit "$status"

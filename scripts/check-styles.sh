#!/usr/bin/env bash
set -euo pipefail

# View / stylesheet hygiene guard, wired into the format-lint CI job.
#
# Locks in the v0.4.x UI-cleanup invariants.  None of these are caught by the
# render tests — a stray inline style or an undefined CSS var renders fine and
# passes every test — so they need a static guard.  The convention:
#
#   * Shared styling lives in Public/styles.css; page-unique styling lives in a
#     view's PageStyle block with role-named classes.
#   * No inline style="" in a view or a JS-built HTML string EXCEPT a
#     JS-toggled `display:none` initial state or a CSS custom-property
#     assignment (e.g. style="--wb-left-width:42%").
#   * No new native alert() in a view or first-party Public/*.js — use the
#     inline .form-error pattern.
#   * Every var(--x) resolves, and no var(--x, #hex) colour fallbacks (see
#     scripts/check-css-vars.sh).
#   * Colours route through the palette (hex only in --token declarations),
#     and font-size / border-radius use the --text-* / --radius-* scales
#     (see scripts/check-design-tokens.sh and docs/ui-design.md).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=lib/css.sh
. "scripts/lib/css.sh"

# Every page is an Elementary view (docs/elementary-spike.md). The rules below
# that grep markup source read the view files; the rules that need rendered
# markup (inline style values, inline scripts and handlers, per-datum custom
# properties, sortable headers) are in Tests/APITests/RenderedMarkupRules.swift
# and run in ElementaryPageGuardTests. Each section below says which.
views=()
while IFS= read -r f; do views+=("$f"); done < <(swift_view_files)
# Page CSS lives in the views' PageStyle literals; rules 4 and 4b read those.
style_views=()
while IFS= read -r f; do style_views+=("$f"); done < <(swift_page_style_files)
if [ "${#views[@]}" -eq 0 ] || [ "${#style_views[@]}" -eq 0 ]; then
  echo "ERROR: check-styles found no Swift view or no PageStyle block under Sources/APIServer/Views."
  echo "       The scan is broken; fix it rather than trusting a vacuous pass."
  exit 1
fi
status=0

# ── 1. CSS custom-property guard ────────────────────────────────────────────
scripts/check-css-vars.sh || status=1

# ── 1b. Design-token guard (palette-only hex, type + radius scales) ─────────
scripts/check-design-tokens.sh || status=1

# ── 1c. Maintenance-page palette sync ────────────────────────────────────────
scripts/check-maintenance-palette.sh || status=1

# ── 2. Inline-style allowlist ───────────────────────────────────────────────
# A style attribute is allowed only if every ;-separated declaration is
# `display:none` or a `--custom-prop:` assignment.  Anything else (margins,
# colours, flex, …) belongs in a semantic class.  Three halves:
#   * here, the string literals of every `.custom(name: "style", …)` call in
#     a Swift view, so a branch that no fixture renders is covered;
#   * RenderedMarkupRules.inlineStyleViolations, run on every rendered fixture
#     by ElementaryPageGuardTests, which also sees a value held in a variable;
#     the SwiftLint rule elementary_no_inline_style bans `.style(`;
#   * rule 3e below, for JS-built HTML strings.
# style_values prints `file:line<TAB>value` for each Swift style attribute.
style_values() { swift_call_literals 'name: "style",' '' "${views[@]}"; }
inline_violations=""
while IFS=$'\t' read -r where value; do
  [ -z "$where" ] && continue
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
  [ "$ok" -eq 0 ] && inline_violations+="  ${where}: style=\"${value}\""$'\n'
done < <(style_values)

if [ -n "$inline_violations" ]; then
  status=1
  echo "ERROR: disallowed inline style=\"\" in a Swift view."
  echo "       Move it to a semantic CSS class.  Inline styles are permitted"
  echo "       only for a JS-toggled display:none or a --custom-prop assignment."
  printf '%s' "$inline_violations"
  echo
fi

# ── 3. No new native alert() in a Swift view ────────────────────────────────
# At ZERO as of the S9 feedback-channel consolidation: every blocking error
# now uses the inline .form-error banner (ChickadeeUI.showActionError). The
# baseline may only go DOWN, so from here the rule is absolute.  A view could
# only carry one in an attribute value or an inline script, and both are
# refused on the rendered page too; this reads the source, so it also sees a
# branch that no fixture renders.
ALERT_BASELINE=0
alert_count="$( { grep -rho 'alert(' "${views[@]}" || true; } | wc -l | tr -d ' ')"
if [ "$alert_count" -gt "$ALERT_BASELINE" ]; then
  status=1
  echo "ERROR: new native alert() in a Swift view (found ${alert_count}, baseline ${ALERT_BASELINE})."
  echo "       Surface errors with the inline .form-error pattern instead."
  grep -rn 'alert(' "${views[@]}" | sed 's/^/  /'
  echo
elif [ "$alert_count" -lt "$ALERT_BASELINE" ]; then
  echo "note: alert() count dropped to ${alert_count}; lower ALERT_BASELINE in scripts/check-styles.sh."
fi

# ── 3a. No new native alert() in first-party JS ─────────────────────────────
# Same rule, same direction, for Public/*.js.  The view ratchet alone was
# leaky: the inline-script rule (3b) pushes page JS out into Public/*.js,
# which the view scan never sees — so an alert() could be laundered out of
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

# ── 3b. Inline <script> is closed (#1135; last holdout retired by #1516) ────
# JS inside an inline <script> block is invisible to every tool — ESLint,
# CodeQL and node --check all skip it.  Page behaviour lives in Public/*.js
# files (loaded with <script src>); a page carries data via data-* attributes
# or a JSON island (JSONIsland.swift).  #1516 moved the last holdout out so
# 'unsafe-inline' could leave the CSP script-src: an inline script added to a
# page would not merely be unlinted, it would NOT RUN.
#
# 3b-2. A one-line inline <script> must be a DATA block (a JSON island); with
# no type, or a JavaScript one, it is executed and blocked by the CSP.
#
# Both rules read markup, so for a Swift view they live on the rendered page:
# RenderedMarkupRules.scriptViolations, run on every fixture by
# ElementaryPageGuardTests.scriptsCarryNoInlineCodeAndNoHandlers.  Its "rule
# fires" check is eachRuleRejectsAPageThatBreaksIt.

# ── 3b-3. No inline event-handler attributes ────────────────────────────────
# An onclick= / onchange= attribute is an inline script by another name, and
# the one shape a CSP nonce cannot rescue — only 'unsafe-inline' (which #1516
# removed) or 'unsafe-hashes' (which we do not grant) permits it.  A handler
# added here does not fail loudly; the control simply stops responding.  The
# replacement is a data attribute read by a delegated listener: see the
# declarative control behaviours at the foot of Public/app.js.
# Two halves.  The HTML strings in Public/*.js that reach the page through
# innerHTML are scanned here, a tag at a time, so a handler on a later line of
# a multi-line tag and one in single quotes are found (#2405).  A Swift view's
# rendered markup is held to the same rule by
# RenderedMarkupRules.scriptViolations; its source is grepped here too for the
# two ways Elementary spells a handler (`.on(.click, …)` and a custom `on…`
# attribute), so a branch no fixture renders is covered.
event_attr_offenders="$(
  awk '
    FNR == 1 && NR > 1 { scan(prev) }
    FNR == 1 { text = ""; prev = FILENAME }
    { text = text $0 "\n" }
    END { if (NR > 0) scan(prev) }
    function scan(file,   rest, line, p, q, pre, tag) {
      rest = text; line = 1
      while ((p = match(rest, /<[a-zA-Z]/)) > 0) {
        pre = substr(rest, 1, p - 1); line += gsub(/\n/, "\n", pre)
        rest = substr(rest, p)
        q = index(rest, ">")
        tag = (q > 0) ? substr(rest, 1, q) : rest
        if (tag ~ /[ \t\n]on[a-z]+[ \t\n]*=/) {
          gsub(/[ \t\n]+/, " ", tag); print file ":" line ": " substr(tag, 1, 120)
        }
        rest = substr(rest, 2)
      }
    }
  ' Public/*.js
  grep -nE '\.on\(\.[a-zA-Z]+|name: *"on[a-z]+"' "${views[@]}" || true
)"
if [ -n "$event_attr_offenders" ]; then
  status=1
  echo "ERROR: inline event-handler attribute in a Swift view or a JS-built HTML string."
  echo "       The CSP script-src carries no 'unsafe-inline', so this handler would"
  echo "       never fire.  Use a data-* attribute plus a delegated listener in"
  echo "       Public/app.js — see the declarative control behaviours there."
  printf '%s\n' "$event_attr_offenders"
  echo
fi

# ── 3c. JS styling-decision ratchet ─────────────────────────────────────────
# Styling written by JavaScript is invisible to every CSS guard above: the
# audit found the type and radius scales 100% bypassed in JS (11 font-size
# literals, none a token), an injected stylesheet with its own dark-mode
# block, and spacing values that would fail rule 4 verbatim in a .css file.
# Counted here, as WRITES only (#2408; a read such as `node.style.fontSize ||`
# decides nothing and used to count): style="…" inside generated-HTML
# strings, `.style.<prop> =` (display toggles exempt — show/hide is
# behaviour, not styling), `.style[prop] =`, `setAttribute('style', …)`,
# `.style.setProperty()` on a non-custom property, cssText, and a <style>
# element built in JS. A custom-property write — .style.setProperty('--…') —
# is the sanctioned pattern and is NOT counted: it carries a value into a rule
# that lives in styles.css, where every guard above can see it. Baseline may
# only go DOWN. The rule for new code
# (docs/ui-design.md): JS toggles classes or sets a custom property
# (workbench.js's --wb-left-width is the pattern); it does not decide
# styling.
JS_STYLE_DECISION_BASELINE=10
js_style_count="$(
  {
    grep -ho 'style="' Public/*.js || true
    grep -hoE '\.style\.[a-zA-Z]+[[:space:]]*=([^=]|$)' Public/*.js | grep -v '^\.style\.display' || true
    grep -hoE '\.style\[[^]]*\][[:space:]]*=([^=]|$)' Public/*.js || true
    grep -hoE "\.style\.setProperty\([[:space:]]*['\"][^-'\"]" Public/*.js || true
    grep -hoE "setAttribute\([[:space:]]*['\"]style['\"]" Public/*.js || true
    grep -ho 'cssText' Public/*.js || true
    grep -hoE "createElement\([[:space:]]*['\"]style['\"]" Public/*.js || true
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
# The same rule Swift views live under (section 2): a style attribute
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
  echo "       state — the same rule Swift views follow."
  printf '%s' "$js_inline_violations"
  echo
fi

# ── 4. No duplicated / shadowed selectors in page <style> blocks ─────────────
# Page-local <style> blocks should only define page-unique classes.  Two
# regressions the cleanup removed (and that render fine, so no test catches):
#   A. a page block re-defines a selector that already lives in the global
#      sheet (e.g. the submission page shadowing the global .achievement-badge);
#   B. the same selector is defined in more than one page block (cross-page
#      duplication that should be hoisted to styles.css).
# `.main` is an allowlisted intentional global override (NotebookBody narrows
# the page container).  Heuristic extractor: selector = text before each `{`
# (one selector per line, as authored here), skipping at-rules and comments —
# errs toward false negatives, never false positives. A one-line
# `@media (...) { .x { ... } }` loses its at-rule prefix first, so `.x` is
# still read (#2403).
ALLOW_GLOBAL_OVERRIDE="^\.main$"

extract_selectors() {
  # `|| true` on the greps so no-match (e.g. a file with no <style> block)
  # doesn't trip pipefail.
  strip_css_comments \
    | { grep '{' || true; } \
    | sed -E 's/^[[:space:]]*@[^{]*\{[[:space:]]*//; s/\{.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | { grep -vE '^$|^@|^/\*' || true; }
}

global_sel="$(extract_selectors < Public/styles.css | sort -u)"

# Build "selector<TAB>file" pairs from every page <style> block.
pairs="$(
  for f in "${style_views[@]}"; do
    base="$(basename "$f")"
    page_style_blocks "$f" | extract_selectors \
      | while IFS= read -r sel; do [ -n "$sel" ] && printf '%s\t%s\n' "$sel" "$base"; done
  done | sort -u
)"

# A. page selector also declared globally (excluding the allowlist).
shadowed=""
while IFS=$'\t' read -r sel file; do
  [ -z "$sel" ] && continue
  if grep -qE "$ALLOW_GLOBAL_OVERRIDE" <<< "$sel"; then continue; fi
  if grep -qxF -- "$sel" <<< "$global_sel"; then
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

# ── 4d. A modifier rule must follow its base rule ───────────────────────────
# `.x--mod` or `.x-mod` on the same element as `.x` overrides it only when it
# comes later: both are one class, so source order decides. A modifier placed
# above its base never applies, and the page still renders, so no test sees
# it (#2399, #2400; #2320 was the same defect). For each top-level rule whose
# selector is one such class, the guard reports a later top-level rule for
# exactly `.x` that sets the same property, when the two class names share a
# line in a Swift view or a first-party JS file (a child element such as
# `.card-meta` is never on the same element as `.card`).
modifier_order_hits="$(
  strip_css_comments < Public/styles.css | awk '
    { css = css $0 "\n" }
    function line_of(pos,   t) { t = substr(css, 1, pos); return gsub(/\n/, "\n", t) + 1 }
    END {
      depth = 0; start = 1; n = 0; cnt = 0
      len = length(css)
      for (i = 1; i <= len; i++) {
        c = substr(css, i, 1)
        if (c == "{") {
          if (depth == 0) {
            sel = substr(css, start, i - start)
            gsub(/^[ \t\n]+|[ \t\n]+$/, "", sel)
            atrule = (substr(sel, 1, 1) == "@")
            bodystart = i + 1
          }
          depth++
        } else if (c == "}") {
          depth--
          if (depth == 0) {
            if (!atrule) {
              n++
              body = substr(css, bodystart, i - bodystart)
              props = ""
              m = split(body, decls, /;/)
              for (k = 1; k <= m; k++) {
                p = decls[k]; sub(/:.*/, "", p); gsub(/[ \t\n]/, "", p)
                if (p != "") props = props " " tolower(p) " "
              }
              nsel = split(sel, parts, /,/)
              for (k = 1; k <= nsel; k++) {
                s = parts[k]; gsub(/^[ \t\n]+|[ \t\n]+$/, "", s)
                if (s !~ /^\.[A-Za-z0-9_-]+$/) continue
                cnt++; rsel[cnt] = substr(s, 2); rord[cnt] = n; rprops[cnt] = props; rline[cnt] = line_of(i)
              }
            }
            start = i + 1
          }
        } else if (c == ";" && depth == 0) {
          start = i + 1
        }
      }
      for (a = 1; a <= cnt; a++) {
        for (b = 1; b <= cnt; b++) {
          if (rord[b] <= rord[a] || index(rsel[a], rsel[b] "-") != 1) continue
          np = split(rprops[a], pa, " ")
          for (k = 1; k <= np; k++) {
            if (pa[k] != "" && index(rprops[b], " " pa[k] " ") > 0) {
              print rsel[a] "\t" rsel[b] "\t" pa[k] "\t" rline[a] "\t" rline[b]
            }
          }
        }
      }
    }'
)"
modifier_order_violations=""
while IFS=$'\t' read -r mod base prop mod_line base_line; do
  [ -z "$mod" ] && continue
  if grep -rhE "(^|[^A-Za-z0-9_-])${base}([^A-Za-z0-9_-]|$)" "${views[@]}" Public/*.js 2>/dev/null \
      | grep -qE "(^|[^A-Za-z0-9_-])${mod}([^A-Za-z0-9_-]|$)"; then
    modifier_order_violations+="  .${mod} (styles.css:${mod_line}) sets ${prop}; .${base} sets it again later (styles.css:${base_line})"$'\n'
  fi
done <<< "$modifier_order_hits"

if [ -n "$modifier_order_violations" ]; then
  status=1
  echo "ERROR: a modifier rule comes before its base rule, so the base rule wins."
  echo "       Move the modifier after the base rule in Public/styles.css."
  printf '%s' "$modifier_order_violations"
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
PAGE_STYLE_BASELINE=254
page_style_count="$(
  for f in "${style_views[@]}"; do page_style_blocks "$f"; done | awk '
    /<style>/ { inblock = 1; next }
    /<\/style>/ { inblock = 0; next }
    inblock && NF > 0 { n++ }
    END { print n + 0 }
  '
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
# implementation, or the readonly-until-focus autofill hack hand-carried in
# markup (the component owns that suppression).  Page JS lives in Public/*.js
# now, so that is where a page-local filter would appear; the component's own
# file is exempt.  The hack is an attribute value, so it is read in the Swift
# views and in JS-built HTML strings.
s1_hack="$(grep -rn "removeAttribute('readonly')" "${views[@]}" || true)
$(grep -n "onfocus=\"this\.removeAttribute('readonly')\"" Public/*.js || true)"
s1_hack="$(sed '/^$/d' <<< "$s1_hack")"
s1_local="$(grep -nE 'function apply[A-Za-z]*Filter' Public/*.js | grep -v '^Public/list-filter\.js:' || true)"
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
# re-assigned in a view.
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
# --share is the same shape on the other axis: a share bar's fill is one row's
# percent of the whole, worked out by the server (Storage, by assignment).
# The avatar props are the second honest case, and the same shape as --bar-h:
# every one carries a palette token chosen for the STUDENT the server is
# rendering, so no stylesheet can hold it and no modifier class could enumerate
# 9,216 of them. They are a closed set, five today, listed with the field each
# reads by AvatarPresentation.inlineProperties (Core/AvatarMarkup.swift).
#
# Two halves read this one list. Here, the literal style values of the Swift
# views (section 2's style_values), so a branch no fixture renders is covered.
# On the rendered page, RenderedMarkupRules.perPageInlinePropertyViolations
# (ElementaryPageGuardTests.inlineCustomPropertiesArePerDatum) reads the list
# from this line, and also sees a value held in a variable, such as the
# avatar's; it asserts every AvatarPresentation.inlineProperties name is here.
PER_DATUM_INLINE_PROPS="--bar-h --share --av-cap --av-wing --av-accent --av-backdrop --av-border"
# Every custom property in the attribute is checked, wherever it sits: the
# first one only, in an attribute that starts with `--`, let a second one or
# one after `display:none;` through (#2404).
inline_prop_violations=""
while IFS=$'\t' read -r where value; do
  [ -z "$where" ] && continue
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    case " $PER_DATUM_INLINE_PROPS " in
      *" $name "*) ;;
      *) inline_prop_violations+="  ${where}: style=\"${value}\""$'\n'; break ;;
    esac
  done < <(printf '%s' "$value" | grep -oE -- '--[A-Za-z0-9_-]+[[:space:]]*:' | sed -E 's/[[:space:]]*:$//')
done < <(style_values)

if [ -n "$inline_prop_violations" ]; then
  status=1
  echo "ERROR: a Swift view assigns a component custom property inline."
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
# th[data-sort-key]::after glyph CSS, the .sort-icon span). Page JS lives in
# Public/*.js, so a page-local sorter is looked for there, outside the
# component's own file. The glyph is looked for in the stylesheets, the page
# CSS and markup of the Swift views, and JS-built HTML.
# A th that declares data-sort-type must carry the shared button, or it is
# decorative markup that sorts nothing. In a Swift view the button sits on a
# later line than the th, so that half reads the rendered page:
# RenderedMarkupRules.orphanSortHeaderViolations
# (ElementaryPageGuardTests.everySortableHeaderCarriesTheSharedButton).
s2_impl="$(grep -nE 'function sort[A-Za-z]*(ByHeader|Rows|Array)' Public/*.js | grep -v '^Public/sortable-table\.js:' || true)"
s2_glyph="$(grep -rnE 'data-sort-key\]::after|class="sort-icon"|\.class\("([^"]* )?sort-icon[ "]' "${views[@]}" Public/*.css Public/*.js || true)"
if [ -n "${s2_impl}${s2_glyph}" ]; then
  status=1
  echo "ERROR: a page re-implements the shared sortable-table idiom."
  echo "       Use .sortable-table + <th data-sort-key data-sort-type>"
  echo "       <button class=\"sort-header\">, and Public/sortable-table.js's"
  echo "       apply() to restore the sort after a repaint."
  { [ -n "$s2_impl" ] && printf '%s\n' "$s2_impl"
    [ -n "$s2_glyph" ] && printf '%s\n' "$s2_glyph"; } | sed 's/^/  /'
  echo
fi

# S4: drawn geometry lives in a sprite and is referenced by a use element.
# Raw path data anywhere else is a new copy of a shape that already exists —
# the trash can had fifteen, in three byte-level variants, which is how "change
# the delete icon" became a grep-and-pray.
#
# TWO files may hold geometry, for two different vocabularies:
# Resources/Sprites/icons.svg is the stroked 24x24 Feather set inlined on every
# page, and Resources/Sprites/avatar-sprite.svg is the flat-filled 64x64
# chickadee parts, included only by pages that show an avatar. A third would
# want the same justification: a distinct vocabulary with a distinct set of
# pages, not just somewhere else to paste a path.
#
# Read: every Swift view, in both spellings (raw markup in a string, and
# Elementary's SVG attributes `.d(`, `.points(`, `.cx(` or a custom attribute
# of those names); JS-built HTML; and every other .svg under Resources/.
s4_svg="$(
  {
    grep -lE '<path d=|<polyline points=|<circle cx=|\.(d|points|cx)\(|name: *"(d|points|cx)"' "${views[@]}" || true
    grep -lE '<path d=|<polyline points=|<circle cx=' Public/*.js || true
    find Resources -name '*.svg' 2>/dev/null \
      | grep -vxE 'Resources/Sprites/(icons|avatar-sprite)\.svg' \
      | while IFS= read -r f; do grep -lE '<path |<polyline |<circle |<polygon |<rect |<ellipse |<line ' "$f" || true; done \
      || true
  } | sed '/^$/d'
)"
if [ -n "$s4_svg" ]; then
  status=1
  echo "ERROR: inline SVG geometry outside the icon sprite."
  echo "       Add a <symbol> to Resources/Sprites/icons.svg and reference it:"
  echo "       Icon(\"name\") in a view, or in JS-built HTML"
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
# The Swift views are read as source: a confirm() there could only sit in an
# attribute value or a script body, which the rendered page refuses as well
# (3b-3), but this also sees a branch no fixture renders.
s5_raw="$(grep -rnE '(^|[^.\w])confirm\(' "${views[@]}" Public/*.js \
  | grep -v 'ChickadeeUI.confirmAction' || true)"
if [ -n "${s5_raw}" ]; then
  status=1
  echo "ERROR: a native confirm() — the shared dialog is the only one."
  echo "       Declare the question in markup with data-confirm=\"…\", or await"
  echo "       ChickadeeUI.confirmAction(msg) where there is no element to mark."
  printf '%s\n' "$s5_raw" | sed 's/^/  /'
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

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
#   * No new native alert() in templates — use the inline .form-error pattern.
#   * Every var(--x) resolves, and no var(--x, #hex) colour fallbacks (see
#     scripts/check-css-vars.sh).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

views=(Resources/Views/*.leaf)
status=0

# ── 1. CSS custom-property guard ────────────────────────────────────────────
scripts/check-css-vars.sh || status=1

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

# ── 3. No new native alert() ────────────────────────────────────────────────
# Baseline = pre-existing alert()s (rare support-file error paths in the
# assignment editors + one mention in a base.leaf comment).  This may only go
# DOWN; new alert()s must use the inline .form-error banner instead.
ALERT_BASELINE=5
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

if [ "$status" -eq 0 ]; then
  echo "check-styles: OK (no disallowed inline styles; alert()s within baseline; no duplicated selectors)"
fi

exit "$status"

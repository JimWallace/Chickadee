#!/usr/bin/env bash
set -uo pipefail

# Response-header assertions against a RUNNING Chickadee.
#
# Why this exists next to a ZAP baseline that already scans the same app: ZAP's
# CSP rule (10055) is one rule covering every CSP finding at once —
# `script-src 'unsafe-inline'`, `script-src 'unsafe-eval'`, `style-src
# 'unsafe-inline'`, wildcard directives. Chickadee permanently accepts one of
# those (`'unsafe-eval'`, which JupyterLab needs to compile schema validators
# at run time), and `.zap/rules.tsv` can only set a threshold per RULE. So the
# accepted finding suppressed the unaccepted ones with it, and a High-severity
# `'unsafe-inline'` sat in the served header through every weekly scan until an
# external AppScan run reported it (#1516).
#
# The lesson is not "stop suppressing": it is that a coarse third-party rule is
# the wrong place to encode a policy this codebase has an exact opinion about.
# The assertions below say precisely what the header must and must not contain,
# so accepting one finding costs nothing in coverage of its neighbours.
#
# The per-directive policy itself is pinned by
# Tests/APITests/ContentSecurityPolicyInlineScriptTests.swift, which needs no
# running server. This script is the end-to-end half: it reads what a client
# actually receives from a booted container, which is the layer a DAST scanner
# sees and the layer a proxy or middleware-ordering mistake can change.
#
# So: do not suppress a coarse third-party rule to accept one of its findings.
# Assert the policy where you have an exact opinion about it (here, and in the
# test above), and leave ZAP rule 10055 at WARN in `.zap/rules.tsv`.
#
# What the policy keeps, and why:
#
# - `script-src` has no `'unsafe-inline'`. An inline `<script>` in a template
#   does not run, and an `onclick=` / `onchange=` attribute never fires.
#   Neither failure is loud. Page JS goes in a `Public/*.js` file; see
#   docs/ui-design.md, "Page-local scripts", and check-styles.sh rules 3b,
#   3b-2 and 3b-3.
# - `'unsafe-eval'` stays. JupyterLab compiles JSON-schema validators at run
#   time. This was measured with Pyodide fully removed.
# - `style-src 'unsafe-inline'` stays. The templates assign CSS custom
#   properties in `style=""`.
# - The vendored JupyterLite entry points carry inline bootstraps that
#   Chickadee does not author. They are allowed by sha256 hash, on
#   `/jupyterlite/` responses only. `EditorInlineScriptHashes` derives the
#   hashes at startup from the bytes that FileMiddleware serves. A hash pinned
#   in source goes stale when a kernel is re-vendored, and the page then
#   breaks before a kernel is fetched, upstream of the editor smoke test.
# - A nonce cannot do this job. The entry points are static files, and the
#   script that most needs a nonce hands the document to `document.write`,
#   which inherits the policy of the writing response.
# - Chickadee's stray-editor-tab page is the one inline script it serves. It
#   is allowed by a hash of the same constant that renders it
#   (`JupyterLiteAppIndexMiddleware.selfCloseScript`). It stays inline because
#   the page must close the tab as soon as it paints, with no fetch that can
#   fail first.
#
# Usage: scripts/check-security-headers.sh [base-url]   (default localhost:8080)

base_url="${1:-http://localhost:8080}"
status=0

headers_of() {
    curl -sS -D - -o /dev/null --max-time 20 "$1" 2>/dev/null
}

header_value() {
    printf '%s\n' "$1" | tr -d '\r' \
        | awk -v name="$2" 'BEGIN { IGNORECASE = 1 } $0 ~ "^" name ":" { sub("^[^:]*: *", ""); print }'
}

directive_of() {
    printf '%s' "$1" | tr ';' '\n' \
        | sed -E 's/^[[:space:]]+//' \
        | awk -v d="$2" 'index($0, d " ") == 1'
}

fail() {
    status=1
    echo "ERROR: $1"
}

# Two paths, both unauthenticated, both reported by the AppScan run: an
# application page and a static asset. They take different middleware exits
# (Leaf render vs FileMiddleware short-circuit), which is exactly how a header
# comes to be present on one and absent on the other.
for path in "/login" "/app.js"; do
    url="${base_url}${path}"
    headers="$(headers_of "$url")"
    if [ -z "$headers" ]; then
        fail "no response from ${url}"
        continue
    fi

    csp="$(header_value "$headers" "Content-Security-Policy")"
    if [ -z "$csp" ]; then
        fail "${path}: no Content-Security-Policy header"
        continue
    fi

    script_src="$(directive_of "$csp" "script-src")"
    if [ -z "$script_src" ]; then
        fail "${path}: CSP has no script-src directive: ${csp}"
    elif grep -q "'unsafe-inline'" <<< "$script_src"; then
        fail "${path}: script-src permits inline execution — ${script_src}"
        echo "       This is the AppScan High (CVSS 8.2) closed by #1516. Page JS"
        echo "       belongs in a Public/*.js file; an event-handler attribute"
        echo "       belongs in a data-* attribute with a delegated listener."
    fi

    for required in \
        "X-Content-Type-Options:nosniff" \
        "X-Frame-Options:SAMEORIGIN" \
        "Referrer-Policy:strict-origin-when-cross-origin" \
        "Cross-Origin-Opener-Policy:same-origin" \
        "Cross-Origin-Resource-Policy:same-origin"
    do
        name="${required%%:*}"
        want="${required#*:}"
        got="$(header_value "$headers" "$name")"
        if [ "$got" != "$want" ]; then
            fail "${path}: ${name} is '${got:-<absent>}', expected '${want}'"
        fi
    done

    if ! grep -q 'camera=()' <<< "$(header_value "$headers" "Permissions-Policy")"; then
        fail "${path}: Permissions-Policy does not deny camera"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "check-security-headers: OK (${base_url} — script-src permits no inline execution; header set intact)"
fi
exit "$status"

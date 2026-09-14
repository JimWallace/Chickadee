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
    elif printf '%s' "$script_src" | grep -q "'unsafe-inline'"; then
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

    if ! printf '%s' "$(header_value "$headers" "Permissions-Policy")" | grep -q 'camera=()'; then
        fail "${path}: Permissions-Policy does not deny camera"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "check-security-headers: OK (${base_url} — script-src permits no inline execution; header set intact)"
fi
exit "$status"

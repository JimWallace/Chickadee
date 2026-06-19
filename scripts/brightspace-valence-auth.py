#!/usr/bin/env python3
"""Obtain a D2L BrightSpace Valence USER ID + USER KEY for grade sync.

Chickadee signs every BrightSpace request with the D2L Valence "App + User" key
model, so it needs FOUR secrets: the registered app's ID/Key (issued by your
D2L admin) *and* a per-account User ID/Key pair. The App ID/Key alone cannot
authenticate a single call — the user pair is what proves the service account
(e.g. `sphs-dev`) authorized this app.

There is no token endpoint; the user pair is obtained once, interactively, via
a browser handshake:

  1. This tool builds a signed URL to the LMS auth handler and opens it.
  2. You log in as the SERVICE ACCOUNT and authorize the app.
  3. D2L redirects to a localhost callback with `?x_a=<userId>&x_b=<userKey>`.
  4. This tool captures those, then verifies them with a live `whoami` call.

The two captured values become Chickadee's BRIGHTSPACE_USER_ID /
BRIGHTSPACE_USER_KEY env vars (see docs/brightspace-setup.md). They are SECRETS
— this tool only prints them to your terminal; it never writes them to disk.

If the D2L auth page rejects the handshake with "x_target does not match the
allowed values for this application," the localhost callback is not on the
app's registered Trusted URL list — a D2L-admin setting. Ask them to allow
`http://localhost` (prefix match). See docs/brightspace-setup.md.

Usage (prefer env vars so the app key never lands in shell history):

    export BRIGHTSPACE_URL=https://learntest.uwaterloo.ca
    export BRIGHTSPACE_APP_ID=...        # D2L Application ID
    export BRIGHTSPACE_APP_KEY=...       # D2L Application Key
    scripts/brightspace-valence-auth.py

Flags:
    --url URL        LMS base URL (default: $BRIGHTSPACE_URL)
    --app-id ID      override $BRIGHTSPACE_APP_ID
    --app-key KEY    override $BRIGHTSPACE_APP_KEY (env is safer)
    --port N         localhost callback port (default 8088)
    --no-browser     print the auth URL instead of opening a browser
    --no-verify      skip the whoami verification call

Stdlib only — no pip install required.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import os
import sys
import time
import urllib.parse
import urllib.request
import webbrowser

AUTH_TOKEN_HANDLER = "/d2l/auth/api/token"
# Must match BrightSpaceSyncConfig in Sources/APIServer/Services/BrightSpaceAPIClient.swift
LP_API_VERSION = "1.28"


def fail(msg: str) -> None:
    print(f"brightspace-valence-auth: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def hmac_sha256_base64url(key: str, message: str) -> str:
    """HMAC-SHA256, base64url-encoded with padding stripped (D2L's `d2l_sig`)."""
    digest = hmac.new(key.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def build_auth_url(host: str, app_id: str, app_key: str, callback: str) -> str:
    """Signed URL the service account visits to authorize the app.

    Per the Valence spec the signature is computed over the RAW callback value,
    while the callback itself is URL-encoded in the `x_target` query parameter.
    """
    sig = hmac_sha256_base64url(app_key, callback)
    return (
        f"{host}{AUTH_TOKEN_HANDLER}"
        f"?x_a={urllib.parse.quote(app_id, safe='')}"
        f"&x_b={urllib.parse.quote(sig, safe='')}"
        f"&x_target={urllib.parse.quote(callback, safe='')}"
    )


def sign_request(host: str, path: str, method: str, app_id: str, app_key: str,
                 user_id: str, user_key: str) -> str:
    """Per-request Valence signing, mirroring BrightSpaceAPIClient.signed(url:method:)."""
    timestamp = int(time.time())
    base_string = f"{timestamp}\n{method.upper()}\n{path.lower()}"
    x_c = hmac_sha256_base64url(app_key, base_string)
    x_d = hmac_sha256_base64url(user_key, base_string)
    return (
        f"{host}{path}"
        f"?x_a={urllib.parse.quote(app_id, safe='')}"
        f"&x_b={urllib.parse.quote(user_id, safe='')}"
        f"&x_c={urllib.parse.quote(x_c, safe='')}"
        f"&x_d={urllib.parse.quote(x_d, safe='')}"
        f"&x_t={timestamp}"
    )


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Captures D2L's redirect (`?x_a=<userId>&x_b=<userKey>`) once, then stops."""

    captured: dict[str, str] = {}

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path.rstrip("/") not in ("/callback", ""):
            self.send_response(404)
            self.end_headers()
            return
        query = urllib.parse.parse_qs(parsed.query)
        user_id = (query.get("x_a") or [""])[0]
        user_key = (query.get("x_b") or [""])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        if user_id and user_key:
            type(self).captured = {"user_id": user_id, "user_key": user_key}
            body = ("<h1>Chickadee — Valence handshake complete</h1>"
                    "<p>User ID and User Key captured. You can close this tab "
                    "and return to the terminal.</p>")
        else:
            body = ("<h1>Handshake failed</h1>"
                    "<p>D2L did not return x_a / x_b. Check the terminal.</p>")
        self.wfile.write(body.encode("utf-8"))

    def log_message(self, *_args) -> None:  # silence per-request stderr logging
        pass


def run_handshake(host: str, app_id: str, app_key: str, port: int,
                  open_browser: bool) -> dict[str, str]:
    callback = f"http://localhost:{port}/callback"
    auth_url = build_auth_url(host, app_id, app_key, callback)

    print("\nStep 1 — authorize the app as the SERVICE ACCOUNT")
    print("  Log in as the D2L account whose grade-write permissions you want")
    print(f"  Callback: {callback}\n")
    if open_browser and webbrowser.open(auth_url):
        print("  Opened your browser. If nothing appeared, visit this URL:\n")
    else:
        print("  Open this URL in a browser logged in as the service account:\n")
    print(f"    {auth_url}\n")

    server = http.server.HTTPServer(("localhost", port), _CallbackHandler)
    print(f"Waiting for the D2L redirect on {callback} … (Ctrl-C to abort)")
    while not _CallbackHandler.captured:
        server.handle_request()
    server.server_close()
    return _CallbackHandler.captured


def verify_whoami(host: str, app_id: str, app_key: str,
                  user_id: str, user_key: str) -> None:
    path = f"/d2l/api/lp/{LP_API_VERSION}/users/whoami"
    url = sign_request(host, path, "GET", app_id, app_key, user_id, user_key)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            import json
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — surface any failure to the operator
        print(f"\n⚠  whoami verification FAILED: {exc}", file=sys.stderr)
        print("   The keys were captured but could not be confirmed. Double-check "
              "BRIGHTSPACE_URL and that you logged in as the right account.",
              file=sys.stderr)
        return
    name = " ".join(p for p in (data.get("FirstName"), data.get("LastName")) if p)
    unique = data.get("UniqueName") or ""
    who = f"{name} ({unique})" if name and unique else (name or unique or data.get("Identifier", "?"))
    print(f"\n✓ Verified — these keys authenticate as: {who}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Obtain a D2L Valence User ID + User Key.")
    parser.add_argument("--url", default=os.environ.get("BRIGHTSPACE_URL"))
    parser.add_argument("--app-id", default=os.environ.get("BRIGHTSPACE_APP_ID"))
    parser.add_argument("--app-key", default=os.environ.get("BRIGHTSPACE_APP_KEY"))
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--no-verify", action="store_true")
    args = parser.parse_args()

    if not args.url:
        fail("missing LMS URL — set BRIGHTSPACE_URL or pass --url")
    if not args.app_id:
        fail("missing app ID — set BRIGHTSPACE_APP_ID or pass --app-id")
    if not args.app_key:
        fail("missing app key — set BRIGHTSPACE_APP_KEY or pass --app-key")

    host = args.url.rstrip("/")
    if not host.startswith(("http://", "https://")):
        fail(f"BRIGHTSPACE_URL must include a scheme, e.g. https://… (got '{host}')")

    captured = run_handshake(host, args.app_id, args.app_key, args.port,
                             open_browser=not args.no_browser)

    if not args.no_verify:
        verify_whoami(host, args.app_id, args.app_key,
                      captured["user_id"], captured["user_key"])

    print("\nStep 2 — add these to the server's environment (these are SECRETS):\n")
    print(f"  BRIGHTSPACE_USER_ID={captured['user_id']}")
    print(f"  BRIGHTSPACE_USER_KEY={captured['user_key']}")
    print("\nKeep them with BRIGHTSPACE_URL / BRIGHTSPACE_APP_ID / BRIGHTSPACE_APP_KEY.")
    print("See docs/brightspace-setup.md for the rest of the wiring.\n")


if __name__ == "__main__":
    main()

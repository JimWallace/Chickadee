#!/usr/bin/env python3
"""Stub the parselmouth mapping fetch in the vendored xeus federated extension.

Upstream jupyterlite-xeus fetches a conda->PyPI package-name mapping from
raw.githubusercontent.com (prefix-dev/parselmouth) at module top level — the
moment the extension chunk loads. JupyterLite activates every federated
extension on every app boot, so the request fires on every editor page load,
for every kernel, Python notebooks included. Our CSP (connect-src 'self',
SecurityHeadersMiddleware) blocks it by policy — student IPs must not reach
third-party hosts on page load (the FIPPA/PIPEDA rule behind the v0.4.171
vendoring) — so the fetch can never succeed; un-patched it just logs a
csp_violation + unhandledrejection pair into client diagnostics on every boot.

The mapping is only consulted by xeus's runtime pip-install path, which
Chickadee never uses: the kernel env is fully baked at build time from
Tools/jupyterlite/environment-r.yml. The stub resolves to a Response-shaped
object carrying an empty mapping, which is the code's own "mapping
unavailable" fallback (identity name-mapping) — minus the network attempt,
the console.error, and the unhandled rejection.

`jupyter lite build` regenerates the extension wherever micromamba is
available, reintroducing the fetch, so build-jupyterlite.sh runs this on every
build and verify-jupyterlite.sh asserts the result. Idempotent: an already-
stubbed chunk is left as-is. Fails loudly if the extension is vendored but
neither the fetch nor the stub is found — the upstream fetch shape drifted, so
re-examine (and retire this patch if upstream stopped fetching at module
load). A build with no xeus extension at all (no micromamba, nothing
committed) is a note-and-skip: check-xeus-vendored.sh owns presence.
"""
import pathlib
import sys

FETCH_CALL = (
    'fetch("https://raw.githubusercontent.com/prefix-dev/parselmouth'
    '/main/files/compressed_mapping.json")'
)

# Response-shaped ({ok, json()}) so every minified continuation — both the
# `A.ok?await A.json():...` and `if(A.ok)return await A.json();...` forms in
# the current chunks — takes its success path and yields the empty mapping.
STUB = "/*chickadee:parselmouth-stub*/Promise.resolve({ok:!0,json:async()=>({})})"


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("Public/jupyterlite")
    static_dir = root / "extensions" / "@jupyterlite" / "xeus-extension" / "static"
    if not static_dir.is_dir():
        print(
            f"patch-xeus-extension: no xeus extension in this build ({static_dir} absent) "
            "— nothing to patch; check-xeus-vendored.sh owns presence for the real tree."
        )
        return 0

    patched = 0
    already = 0
    for path in sorted(static_dir.glob("*.js")):
        text = path.read_text()
        if FETCH_CALL in text:
            path.write_text(text.replace(FETCH_CALL, STUB))
            patched += 1
        elif STUB in text:
            already += 1

    if patched:
        print(f"patch-xeus-extension: stubbed the parselmouth fetch in {patched} chunk(s)")
    if already:
        print(f"patch-xeus-extension: already stubbed in {already} chunk(s) — no-op")
    if not patched and not already:
        print(
            "patch-xeus-extension: FAIL — neither the parselmouth fetch nor the stub "
            f"found in any chunk under {static_dir}. The upstream jupyterlite-xeus "
            "fetch shape drifted; re-examine (and retire this patch if upstream no "
            "longer fetches the mapping at module load).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

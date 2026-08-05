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
Tools/jupyterlite/environment.yml. The stub resolves to a Response-shaped
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

Stage 2 — cache buster (CACHE_BUST). The extension's content-hash-named
chunks are served immutable for a year (EditorAssetFastPathMiddleware), on
the premise that bytes behind a hashed name never change. The v0.4.665 stub
broke that premise for the three patched chunks: every browser that loaded
the editor between the xeus bundle shipping and the stub deploying holds the
fetch-bearing bytes immutably and will never revalidate them. Changing
server headers cannot reach an already-cached immutable entry — only a URL
change can. So this stage rewrites the URLs the loader mints, orphaning the
stale entries:
  * in every xeus static chunk carrying the webpack chunk-URL template
    (`+".js?v="+<hash-map>[id]`), the query becomes `?v=ck1<hash>`;
  * in the built jupyter-lite.json, the xeus federated entry's `load` gains
    `?ck1` — the bootstrap composes the script URL from it verbatim
    (`${fullLabextensionsUrl}/${name}/${load}` in build/*/bundle.js), and
    jupyter-lite.json itself is served with ETag revalidation, making it the
    reliable top of the invalidation chain.
Old URLs keep resolving to the same (patched) files on disk, so clients with
a stale config never 404. Bump CACHE_BUST only if vendored-chunk bytes are
ever again changed in place under unchanged names; an upstream re-vendor
mints new hashes and does not need a bump (the buster is then redundant but
harmless, and keeping it applied keeps the verify guard unconditional).
"""
import json
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

CACHE_BUST = "ck1"

# The webpack chunk-URL template as emitted by the upstream build
# (`...+".js?v="+({4:"1325...",...})[id]`) and its busted form. The bare
# template appears exactly once per loader-carrying chunk; the replacement
# turns every minted chunk URL into `<id>.<hash>.js?v=ck1<hash>`.
CHUNK_QUERY = '".js?v="'
CHUNK_QUERY_BUSTED = f'".js?v={CACHE_BUST}"'

XEUS_EXTENSION_NAME = "@jupyterlite/xeus-extension"

# Appended to the federated entry's `load` path. Same token as the chunk
# query so one CACHE_BUST bump rolls the whole chain.
LOAD_QUERY = f"?{CACHE_BUST}"


def fail(message: str) -> int:
    print(f"patch-xeus-extension: FAIL — {message}", file=sys.stderr)
    return 1


def bust_config(root: pathlib.Path) -> int:
    """Append LOAD_QUERY to the xeus federated entry's `load` in the built
    jupyter-lite.json, via an exact-token splice so the generated file's
    formatting is otherwise untouched. Returns a process exit code."""
    config_path = root / "jupyter-lite.json"
    if not config_path.is_file():
        return fail(f"xeus extension is vendored but {config_path} is missing.")
    raw = config_path.read_text()
    entries = (
        json.loads(raw).get("jupyter-config-data", {}).get("federated_extensions", [])
    )
    entry = next(
        (e for e in entries if isinstance(e, dict) and e.get("name") == XEUS_EXTENSION_NAME),
        None,
    )
    if entry is None:
        return fail(
            f"xeus extension is vendored but {XEUS_EXTENSION_NAME} is not in "
            f"federated_extensions of {config_path} — incoherent bundle."
        )
    load = entry.get("load")
    if not load:
        return fail(f"the {XEUS_EXTENSION_NAME} federated entry has no `load` field.")
    if load.endswith(LOAD_QUERY):
        print("patch-xeus-extension: jupyter-lite.json load already cache-busted — no-op")
        return 0
    if "?" in load:
        return fail(
            f"the xeus `load` path already carries an unexpected query ({load!r}); "
            "upstream changed shape — re-examine before stacking cache busters."
        )
    old_token = json.dumps(load)
    if raw.count(old_token) != 1:
        return fail(
            f"expected exactly one occurrence of {old_token} in {config_path}, "
            f"found {raw.count(old_token)} — refusing an ambiguous splice."
        )
    updated = raw.replace(old_token, json.dumps(load + LOAD_QUERY))
    json.loads(updated)
    config_path.write_text(updated)
    print(f"patch-xeus-extension: cache-busted jupyter-lite.json load ({load}{LOAD_QUERY})")
    return 0


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
    busted = 0
    bust_already = 0
    for path in sorted(static_dir.glob("*.js")):
        text = path.read_text()
        original = text
        if FETCH_CALL in text:
            text = text.replace(FETCH_CALL, STUB)
            patched += 1
        elif STUB in text:
            already += 1
        # Busted-first: CHUNK_QUERY is a prefix of CHUNK_QUERY_BUSTED, so the
        # bare-template branch must only run when the busted form is absent.
        if CHUNK_QUERY_BUSTED in text:
            bust_already += 1
        elif CHUNK_QUERY in text:
            text = text.replace(CHUNK_QUERY, CHUNK_QUERY_BUSTED)
            busted += 1
        if text != original:
            path.write_text(text)

    if patched:
        print(f"patch-xeus-extension: stubbed the parselmouth fetch in {patched} chunk(s)")
    if already:
        print(f"patch-xeus-extension: already stubbed in {already} chunk(s) — no-op")
    if not patched and not already:
        return fail(
            "neither the parselmouth fetch nor the stub found in any chunk under "
            f"{static_dir}. The upstream jupyterlite-xeus fetch shape drifted; "
            "re-examine (and retire this patch if upstream no longer fetches the "
            "mapping at module load)."
        )

    if busted:
        print(f"patch-xeus-extension: cache-busted the chunk-URL template in {busted} file(s)")
    if bust_already:
        print(f"patch-xeus-extension: chunk-URL template already busted in {bust_already} file(s) — no-op")
    if not busted and not bust_already:
        return fail(
            f"no chunk-URL template ({CHUNK_QUERY} or busted form) found in any file "
            f"under {static_dir}. The upstream webpack loader shape drifted; the "
            "cache buster would silently stop applying — re-examine."
        )

    return bust_config(root)


if __name__ == "__main__":
    sys.exit(main())

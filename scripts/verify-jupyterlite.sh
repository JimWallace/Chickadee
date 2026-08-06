#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/Public/jupyterlite}"
CONFIG_PATH="$BUILD_DIR/jupyter-lite.json"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "missing config: $CONFIG_PATH" >&2
  exit 1
fi

python3 - "$CONFIG_PATH" "$BUILD_DIR" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
build_dir = pathlib.Path(sys.argv[2])
cfg = json.loads(config_path.read_text())
data = cfg.get("jupyter-config-data", {})

def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)

# The editor's Python kernel is xeus-python (`xpython`). The Pyodide kernel
# extension was retired in v0.5.19; both kernels are xeus now, so the assertions
# that used to pin pyodideUrl and the piplite sha-cascade are gone with it.
if data.get("defaultKernelName") != "xpython":
    fail("defaultKernelName must be 'xpython'")

if data.get("fullLabextensionsUrl") != "./extensions":
    fail("fullLabextensionsUrl must be './extensions'")

# Nothing may reintroduce a Pyodide dependency by the back door: the whole point
# of the retirement is that no code path loads it, so a reappearing federated
# extension or plugin setting is a regression, not a config detail.
federated = data.get("federated_extensions", [])
names = {entry.get("name") for entry in federated if isinstance(entry, dict)}
settings = data.get("litePluginSettings", {})
for name in sorted(names) + sorted(settings):
    if "pyodide" in name:
        fail(
            f"{name} is back in jupyter-lite.json. Pyodide was retired in v0.5.19 "
            "along with the vendored Public/pyodide it needed; re-adding the kernel "
            "means re-vendoring ~465 MB and restoring its CSP allowances."
        )

# The xeus extension is what actually serves both kernels now.
xeus_static = build_dir / "extensions" / "@jupyterlite" / "xeus-extension" / "static"
remote_entries = [
    p for p in sorted(xeus_static.glob("remoteEntry.*.js")) if not p.name.endswith(".map")
]
if not remote_entries:
    fail(f"missing extension asset: no remoteEntry.*.js under {xeus_static}")
if len(remote_entries) > 1:
    fail(f"unexpected: multiple remoteEntry.*.js under {xeus_static}: {[p.name for p in remote_entries]}")

config_utils = (build_dir / "config-utils.js").read_text()
if "const originalList = (config || {}).federated_extensions || [];" not in config_utils:
    fail("config-utils.js is missing federated extension list fix")
if "config.federated_extensions = allExtensions;" not in config_utils:
    fail("config-utils.js is missing federated extension assignment fix")

# The Atomics.waitAsync polyfill worker must be the blob: form
# (scripts/patch-waitasync-worker.py). A data: worker is blocked by our CSP
# (worker-src 'self' blob:) and COEP, so an un-patched chunk hangs the kernel on
# engines without native waitAsync (older Safari / iPadOS).
#
# Scans EVERY federated extension, not one. This guard and its patch script were
# scoped to the pyodide-kernel extension, and when Pyodide was retired it turned
# out the xeus extension shipped the identical un-patched polyfill — in the
# kernel Chickadee actually runs, for both languages. A per-extension scope is
# how that went unseen; a glob is how it stays seen.
data_worker_chunks = [
    p.name
    for p in sorted((build_dir / "extensions").glob("@jupyterlite/*/static/*.js"))
    if "data:application/javascript,onmessage" in p.read_text()
]
if data_worker_chunks:
    fail(
        f"a waitAsync polyfill still uses a data: worker in {data_worker_chunks} — "
        "run scripts/patch-waitasync-worker.py (build-jupyterlite.sh does this)."
    )

# The in-iframe kernel-boot diagnostics collector must be injected into the
# kernel-bearing editor documents (scripts/patch-jupyterlite-diagnostics.py). A
# `jupyter lite build` regenerates these index.html files and would drop the
# <script> tag; without it the collector never runs and the kernel boot is
# invisible again. Assert it's present so a rebuild that forgets the patch fails
# here, not silently in front of a student. The tag carries a ?v=<hash> derived
# from the collector's bytes (cache-buster); assert the hash matches the current
# script so a stale tag — which would serve students an old cached collector
# after the script changed — fails here, not silently in the browser.
import hashlib
import re

diag_source = build_dir.parent / "jl-kernel-diagnostics.js"
if not diag_source.is_file():
    fail(f"missing kernel-diagnostics collector source: {diag_source}")
expected_hash = hashlib.sha256(diag_source.read_bytes()).hexdigest()[:8]
expected_tag = f'<script src="/jl-kernel-diagnostics.js?v={expected_hash}"></script>'
diag_tag_re = re.compile(r'<script src="/jl-kernel-diagnostics\.js\?v=([0-9a-f]+)"></script>')
for rel in ("notebooks/index.html", "repl/index.html"):
    index_path = build_dir / rel
    if not index_path.is_file():
        fail(f"missing editor document: {index_path}")
    found = diag_tag_re.search(index_path.read_text())
    if not found:
        fail(
            f"{rel} is missing the cache-busted kernel-diagnostics collector tag — "
            "run scripts/patch-jupyterlite-diagnostics.py (build-jupyterlite.sh does this)."
        )
    if found.group(1) != expected_hash:
        fail(
            f"{rel} has a stale kernel-diagnostics cache-buster "
            f"(?v={found.group(1)}, expected ?v={expected_hash}) — the collector changed "
            "but the tag was not re-patched; run scripts/patch-jupyterlite-diagnostics.py."
        )

# The vendored xeus extension must not fetch the parselmouth conda->pip mapping
# from raw.githubusercontent.com at module load (scripts/patch-xeus-extension.py
# stubs it; build-jupyterlite.sh applies it). The CSP (connect-src 'self')
# blocks the request by policy — student IPs must not reach third-party hosts —
# so an un-patched chunk can never fetch it anyway; it just emits a
# csp_violation + unhandledrejection diagnostics pair on every editor boot.
# Skipped when the extension isn't vendored: check-xeus-vendored.sh owns
# presence.
xeus_static = build_dir / "extensions" / "@jupyterlite" / "xeus-extension" / "static"
if xeus_static.is_dir():
    unpatched = [
        p.name
        for p in sorted(xeus_static.glob("*.js"))
        if "raw.githubusercontent.com/prefix-dev/parselmouth" in p.read_text()
    ]
    if unpatched:
        fail(
            "xeus-extension chunks still fetch the parselmouth mapping from "
            f"raw.githubusercontent.com: {unpatched} — run "
            "scripts/patch-xeus-extension.py (build-jupyterlite.sh does this)."
        )

    # The same patch's cache-buster chain must be intact (its stage 2). The
    # extension's hashed chunks are served immutable for a year; the stub
    # changed bytes in place under unchanged names, so clients that loaded the
    # editor pre-stub hold the fetch-bearing chunks immutably and only a URL
    # change reaches them. Assert (a) no loader file still mints bare
    # `.js?v=<hash>` chunk URLs, and (b) the federated `load` for the xeus
    # extension carries the buster and names a file that exists — so a rebuild
    # that drops the buster, or a remoteEntry rename that outruns the config,
    # fails here instead of stranding stale caches (or 404ing the extension).
    bare_template = [
        p.name
        for p in sorted(xeus_static.glob("*.js"))
        if '".js?v="' in p.read_text()
    ]
    if bare_template:
        fail(
            f"xeus-extension loader files still mint un-busted chunk URLs: {bare_template} "
            "— run scripts/patch-xeus-extension.py (build-jupyterlite.sh does this)."
        )
    xeus_entry = next(
        (
            e
            for e in federated
            if isinstance(e, dict) and e.get("name") == "@jupyterlite/xeus-extension"
        ),
        None,
    )
    if xeus_entry is None:
        fail("xeus extension is vendored but missing from federated_extensions")
    xeus_load = xeus_entry.get("load", "")
    if "?ck" not in xeus_load:
        fail(
            f"xeus federated load {xeus_load!r} lacks the ?ck cache buster — run "
            "scripts/patch-xeus-extension.py (build-jupyterlite.sh does this)."
        )
    load_file = build_dir / "extensions" / "@jupyterlite" / "xeus-extension" / xeus_load.split("?", 1)[0]
    if not load_file.is_file():
        fail(f"xeus federated load points at a missing file: {load_file}")

print("JupyterLite verification passed.")
PY

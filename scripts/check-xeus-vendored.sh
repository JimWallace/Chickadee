#!/usr/bin/env bash
# Integrity guard for the manually-vendored xeus kernels in Public/jupyterlite:
# xpython (Python) and xr (R), built together from one emscripten-forge env.
#
# The xeus WASM kernels are built from emscripten-forge (needs micromamba +
# network to repo.prefix.dev). The ordinary CI build does not do that, so the
# committed bytes under Public/jupyterlite/xeus/ are authoritative — the
# reproducibility check (jupyterlite.yml) excludes that path. This script asserts
# the vendored kernel is present and internally coherent, so a botched or partial
# re-vendor is caught in CI instead of in front of a student.
#
# Note what this canNOT see: it compares the vendored tree to ITSELF, so a kernel
# that is perfectly coherent but missing a package the environment file asks for
# passes every check here. That is how scipy/sympy/scikit-learn/statsmodels were
# declared and shipped absent. scripts/check-env-vendored-sync.sh covers that
# axis. Rebuild with .github/workflows/revendor-kernels.yml, or locally with
# scripts/build-jupyterlite.sh. See docs/xeus-r-kernel-spike.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/Public/jupyterlite}"

python3 - "$BUILD_DIR" <<'PY'
import json
import pathlib
import sys

build = pathlib.Path(sys.argv[1])


def fail(msg: str) -> None:
    print(f"check-xeus-vendored: {msg}", file=sys.stderr)
    sys.exit(1)


# 1. The xeus federated extension wires the kernel into the editor UI.
ext = build / "extensions" / "@jupyterlite" / "xeus-extension"
if not ext.is_dir():
    fail(f"missing xeus federated extension: {ext}")

# 2. kernels.json must register BOTH editor kernels: xpython (Python) and xr (R).
#    A vendor that drops either one is a partial re-vendor, not a valid state.
kernels_json = build / "xeus" / "kernels.json"
if not kernels_json.is_file():
    fail(f"missing {kernels_json} — the vendored xeus kernels are absent")
kernels = json.loads(kernels_json.read_text())
listed = sorted(k.get("kernel") for k in kernels if isinstance(k, dict))

expected_language = {"xpython": "python", "xr": "r"}
kernel_envs = {}
loaders = []

for kernel_name, language in sorted(expected_language.items()):
    entries = [k for k in kernels if isinstance(k, dict) and k.get("kernel") == kernel_name]
    if not entries:
        fail(f"{kernel_name} kernel not registered in kernels.json: {listed}")
    env_name = entries[0].get("env_name")
    if not env_name:
        fail(f"no env_name for the {kernel_name} kernel in kernels.json")
    kernel_envs[kernel_name] = env_name

    # 3. The kernelspec must exist and declare the expected language.
    spec_path = build / "xeus" / env_name / kernel_name / "kernel.json"
    if not spec_path.is_file():
        fail(f"missing {kernel_name} kernelspec: {spec_path}")
    spec = json.loads(spec_path.read_text())
    if (spec.get("language") or "").lower() != language:
        fail(
            f"{kernel_name} kernelspec language is not {language}: "
            f"{spec.get('language')!r}"
        )

    # 4. The kernel loader named by argv[0] (the WASM bootstrap) must exist, as
    #    must the .wasm beside it — a loader with no binary is the classic
    #    half-copied vendor.
    argv = spec.get("argv", [])
    loader_rel = argv[0] if argv else None
    if not loader_rel:
        fail(f"{kernel_name} kernelspec has no argv/loader")
    if not (build / loader_rel).is_file():
        fail(f"{kernel_name} kernel loader missing: {build / loader_rel} (argv[0]={loader_rel!r})")
    wasm = (build / loader_rel).with_suffix(".wasm")
    if not wasm.is_file():
        fail(f"{kernel_name} kernel WASM binary missing: {wasm}")
    loaders.append(loader_rel)

# 5. Each kernel must live in its OWN env, and each env must carry a non-trivial
#    packed payload.
#
#    The separation is load-bearing, not cosmetic: a kernel fetches its whole env
#    at boot, so putting Python and R in one env makes every Python boot pull
#    r-base and every R boot pull numpy/pandas/matplotlib. That was slow enough
#    to time out the editor probes with "kernel never reported idle". Assert the
#    envs stay distinct so a re-vendor cannot silently recombine them.
if len(set(kernel_envs.values())) != len(kernel_envs):
    fail(
        "xeus kernels must each have their own env (a shared env makes every "
        f"kernel boot fetch both languages' payloads): {kernel_envs}"
    )

package_counts = {}
for kernel_name, env_name in sorted(kernel_envs.items()):
    kernel_packages = build / "xeus" / env_name / "kernel_packages"
    pkgs = sorted(kernel_packages.glob("*.tar.gz")) if kernel_packages.is_dir() else []
    if len(pkgs) < 5:
        fail(f"xeus/{env_name}/kernel_packages looks empty/partial: {len(pkgs)} package(s)")
    package_counts[kernel_name] = len(pkgs)

    # The Python env must not carry R, and vice versa — the recombination this
    # guard exists to prevent would otherwise show up only as a slow boot.
    names = [p.name for p in pkgs]
    if kernel_name == "xpython" and any(n.startswith("r-base-") for n in names):
        fail(f"xeus/{env_name} (Python) contains r-base — the envs have been merged")
    if kernel_name == "xr" and any(n.startswith(("numpy-", "pandas-")) for n in names):
        fail(f"xeus/{env_name} (R) contains numpy/pandas — the envs have been merged")

print(
    f"check-xeus-vendored: OK "
    f"(kernels {listed}, envs {kernel_envs}, packages {package_counts}, loaders {loaders})."
)

# 6. The Python env's derived module index must exist and match the env that
#    ships beside it. The server reads it to reject a browser-graded script
#    whose imports the kernel cannot satisfy; a stale index either blocks a
#    package that is now vendored or accepts one that was dropped, and both are
#    silent. Regenerate with scripts/derive-kernel-modules.py (build-jupyterlite
#    already does).
python_env = build / "xeus" / "chickadee-python"
if python_env.is_dir():
    index_path = python_env / "importable-modules.json"
    if not index_path.is_file():
        fail(
            f"missing {index_path} — run scripts/derive-kernel-modules.py {python_env}"
        )
    index = json.loads(index_path.read_text())
    meta = json.loads((python_env / "empack_env_meta.json").read_text())
    vendored = sorted({p["name"] for p in meta.get("packages", [])})
    if index.get("packages") != vendored:
        fail(
            "importable-modules.json describes a different package set than "
            f"empack_env_meta.json ({len(index.get('packages', []))} vs {len(vendored)} "
            f"packages) — re-run scripts/derive-kernel-modules.py {python_env}"
        )
    if not index.get("modules") or not index.get("stdlibModules"):
        fail(f"{index_path} lists no modules — regenerate it")
    print(
        f"check-xeus-vendored: OK (module index matches the env: "
        f"{len(index['modules'])} package modules)."
    )
PY

# 6. The pyodide-http payload in the Python env must carry the streaming-path
#    patch (scripts/patch-xeus-python-http.py). pyodide-http selects a
#    Pyodide-specific streaming implementation whenever `crossOriginIsolated` is
#    true; it is not pyjs-compatible, so on an isolated engine the kernel never
#    leaves `kernel_starting` and the editor sits on "Kernel Connecting".
#
#    This is easy to ship broken by accident: the failure is invisible in the
#    JupyterLite REPL (no Drive-backed file, so no HTTP call happens) AND
#    invisible on WebKit (served non-isolated, so it takes the working fallback
#    anyway). Only isolated engines hit it. Assert it on the committed bytes
#    rather than trusting any one smoke config to catch it.
python3 - "$BUILD_DIR" <<'PY'
import pathlib
import sys
import tarfile

build = pathlib.Path(sys.argv[1])
archives = sorted((build / "xeus").glob("*/kernel_packages/pyodide-http-*.tar.gz"))
if not archives:
    print("check-xeus-vendored: no pyodide-http payload (R-only vendor) — patch check skipped.")
    sys.exit(0)

for archive in archives:
    with tarfile.open(archive, "r:gz") as tf:
        members = [m for m in tf.getmembers() if m.name.endswith("pyodide_http/_streaming.py")]
        if not members:
            print(
                f"check-xeus-vendored: {archive.name} has no pyodide_http/_streaming.py "
                "— upstream layout changed, re-check scripts/patch-xeus-python-http.py",
                file=sys.stderr,
            )
            sys.exit(1)
        extracted = tf.extractfile(members[0])
        source = extracted.read().decode("utf-8") if extracted else ""
    # The load-bearing edit: the streaming path must be unreachable. Test for
    # the live `if crossOriginIsolated:` switch rather than for the patch's own
    # marker, so a partially-applied patch cannot pass.
    if "if crossOriginIsolated:" in source:
        print(
            f"check-xeus-vendored: {archive.name} still selects pyodide-http's streaming "
            "path under cross-origin isolation — run scripts/patch-xeus-python-http.py "
            "(the editor kernel hangs on isolated engines without it)",
            file=sys.stderr,
        )
        sys.exit(1)
    # Secondary edit, only reachable if streaming is ever re-enabled.
    if "dict_converter=" in source:
        print(
            f"check-xeus-vendored: {archive.name} still calls to_js(dict_converter=...) "
            "— run scripts/patch-xeus-python-http.py",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"check-xeus-vendored: OK (pyodide-http streaming path disabled in {archive.name}).")

# 8. The SAME hazard in urllib3, which arrives transitively with scikit-learn
#    (scikit-learn -> requests -> urllib3). Its emscripten module builds a
#    streaming fetcher at MODULE IMPORT under exactly a grading worker's
#    conditions, and that constructor calls Pyodide's to_js(dict_converter=...).
#    Un-patched, xkernel.start() raises and the kernel does not boot AT ALL —
#    total, not degraded. Asserted separately from the patch script so shipping
#    an un-patched re-vendor is a CI failure rather than a dead editor.
urllib3_archives = sorted((build / "xeus").glob("*/kernel_packages/urllib3-*.tar.gz"))
for archive in urllib3_archives:
    with tarfile.open(archive, "r:gz") as tf:
        members = [
            m for m in tf.getmembers()
            if m.name.endswith("site-packages/urllib3/contrib/emscripten/fetch.py")
        ]
        if not members:
            print(
                f"check-xeus-vendored: {archive.name} has no urllib3 emscripten fetch.py "
                "— upstream layout changed; re-check scripts/patch-xeus-python-http.py",
                file=sys.stderr,
            )
            sys.exit(1)
        extracted = tf.extractfile(members[0])
        source = extracted.read().decode("utf-8") if extracted else ""
    # Test for the live construction, not the patch marker, so a partially
    # applied patch cannot pass.
    if "_fetcher = _StreamingFetcher()" in source:
        print(
            f"check-xeus-vendored: {archive.name} still constructs urllib3's streaming "
            "fetcher at import — run scripts/patch-xeus-python-http.py (the kernel does "
            "not boot at all on isolated engines without it)",
            file=sys.stderr,
        )
        sys.exit(1)
    if "dict_converter=" in source:
        print(
            f"check-xeus-vendored: {archive.name} still calls to_js(dict_converter=...) "
            "— run scripts/patch-xeus-python-http.py",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"check-xeus-vendored: OK (urllib3 streaming fetcher suppressed in {archive.name}).")

PY

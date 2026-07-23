#!/usr/bin/env bash
# Integrity guard for the manually-vendored xeus-r kernel in Public/jupyterlite.
#
# The xeus-r WASM kernel is built from emscripten-forge (needs micromamba +
# network to repo.prefix.dev), which CI does not have. So CI never rebuilds it
# and the committed bytes under Public/jupyterlite/xeus/ are authoritative — the
# reproducibility check (jupyterlite.yml) excludes that path. This script asserts
# the vendored kernel is present and internally coherent, so a botched or partial
# re-vendor is caught in CI instead of in front of a student. Rebuild the kernel
# with scripts/build-jupyterlite.sh where micromamba + emscripten-forge are
# reachable (a maintainer machine). See docs/xeus-r-kernel-spike.md.
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

# 2. kernels.json must register the xr (R) kernel.
kernels_json = build / "xeus" / "kernels.json"
if not kernels_json.is_file():
    fail(f"missing {kernels_json} — the vendored xeus kernel is absent")
kernels = json.loads(kernels_json.read_text())
xr = [k for k in kernels if isinstance(k, dict) and k.get("kernel") == "xr"]
if not xr:
    listed = sorted(k.get("kernel") for k in kernels if isinstance(k, dict))
    fail(f"xr (R) kernel not registered in kernels.json: {listed}")
env_name = xr[0].get("env_name")
if not env_name:
    fail("no env_name for the xr kernel in kernels.json")

# 3. The xr kernelspec must exist and declare R.
spec_path = build / "xeus" / env_name / "xr" / "kernel.json"
if not spec_path.is_file():
    fail(f"missing xr kernelspec: {spec_path}")
spec = json.loads(spec_path.read_text())
if (spec.get("language") or "").lower() != "r":
    fail(f"xr kernelspec language is not R: {spec.get('language')!r}")

# 4. The kernel loader named by argv[0] (the WASM bootstrap) must exist.
argv = spec.get("argv", [])
loader_rel = argv[0] if argv else None
if not loader_rel:
    fail("xr kernelspec has no argv/loader")
if not (build / loader_rel).is_file():
    fail(f"xr kernel loader missing: {build / loader_rel} (argv[0]={loader_rel!r})")

# 5. The packed R package payload must be non-trivial (guards a truncated vendor).
kernel_packages = build / "xeus" / env_name / "kernel_packages"
pkgs = sorted(kernel_packages.glob("*.tar.gz")) if kernel_packages.is_dir() else []
if len(pkgs) < 5:
    fail(f"xeus/{env_name}/kernel_packages looks empty/partial: {len(pkgs)} package(s)")

print(
    f"check-xeus-vendored: OK "
    f"(xr kernel, language R, {len(pkgs)} packages, loader {loader_rel})."
)
PY

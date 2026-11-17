#!/usr/bin/env bash
set -euo pipefail

# Installs the pinned micromamba into ~/.local/bin for a GitHub Actions job,
# and puts that directory on the PATH of the next steps. kernel-currency.yml
# and revendor-kernels.yml both use it: the first to solve the kernel
# environments, the second to install them from their locks.
#
# PINNED, by version and sha256. micromamba installs every kernel package, so
# it is part of what the kernel bytes depend on. It used to be "latest", with
# no check on what was downloaded. To move it, take the conda-forge package
# that https://micro.mamba.pm/api/micromamba/linux-64/latest redirects to,
# record its URL and the sha256 of the downloaded file here, and re-vendor.

version="2.10.0-0"
url="https://conda.anaconda.org/conda-forge/linux-64/micromamba-${version}.tar.bz2"
sha256="9a97976244929bbae28fb1fae504e74a3e7e6d1932870e3a03321f01b7fbd07b"

bin_dir="$HOME/.local/bin"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$bin_dir"
curl -sSL --fail --max-time 180 "$url" -o "$tmp_dir/micromamba.tar.bz2"
echo "$sha256  $tmp_dir/micromamba.tar.bz2" | sha256sum --check --quiet
tar -xj -C "$tmp_dir" -f "$tmp_dir/micromamba.tar.bz2" bin/micromamba
mv "$tmp_dir/bin/micromamba" "$bin_dir/micromamba"
echo "$bin_dir" >> "$GITHUB_PATH"

#!/usr/bin/env bash
set -euo pipefail

# Installs the latest micromamba into ~/.local/bin for a GitHub Actions job,
# and puts that directory on the PATH of the next steps. kernel-currency.yml
# and revendor-kernels.yml both build the kernel environments with it.

bin_dir="$HOME/.local/bin"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$bin_dir"
curl -sSL --max-time 180 \
  https://micro.mamba.pm/api/micromamba/linux-64/latest -o "$tmp_dir/micromamba.tar.bz2"
tar -xj -C "$tmp_dir" -f "$tmp_dir/micromamba.tar.bz2" bin/micromamba
mv "$tmp_dir/bin/micromamba" "$bin_dir/micromamba"
echo "$bin_dir" >> "$GITHUB_PATH"

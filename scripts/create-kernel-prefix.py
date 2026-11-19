#!/usr/bin/env python3
"""Install one xeus kernel environment from its lock, at a fixed path.

`scripts/build-jupyterlite.sh` calls this once per environment and hands the
result to jupyterlite-xeus as `--XeusAddon.prefix`. Before, jupyterlite-xeus
solved each environment file itself, into a random temporary directory. That
had two costs:

  * the solve picked whatever the channels held that day, so any rebuild also
    upgraded every package (the locks fix this: scripts/lock-kernel-envs.py);
  * the install path is written into the kernel binary. conda replaces the
    package's build prefix with the install prefix in binary files, padded
    with null bytes, so `xpython.wasm` carried the random path, and no two
    builds of the same environment were byte-identical.

So this installs from the lock (micromamba refuses a file whose sha256 is not
the lock's), never solves, and always at `/tmp/chickadee-xeus/envs/<name>`. The path is a constant, not a setting: it
must be the same on every machine that builds the kernels, or the builds
differ again. On macOS `/tmp` is a link to `/private/tmp`; the build still
works there, but its bytes differ from a Linux build, and this says so.

jupyterlite-xeus reads two things from the environment's conda-meta/history
in prefix mode: the specs (`# update specs:`), which it records in
empack_env_meta.json, and the channels (`-c` in a `# cmd:` line). An install
from a lock writes neither, so this records both, with the values the
environment file declares. `scripts/check-env-vendored-sync.sh` compares those
specs with the environment file.

Usage: create-kernel-prefix.py <environment-x.yml> <environment-x-lock.yml>
Prints the prefix it created. Run it with the JupyterLite venv's Python, which
has PyYAML (jupyterlite-xeus depends on it).
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys

import yaml

PREFIX_ROOT = pathlib.Path("/tmp/chickadee-xeus")
PLATFORM = "emscripten-wasm32"
SCRIPTS = pathlib.Path(__file__).resolve().parent


def fail(message: str) -> None:
    print(f"create-kernel-prefix: {message}", file=sys.stderr)
    sys.exit(1)


def lock_module():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("lock_kernel_envs", SCRIPTS / "lock-kernel-envs.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: create-kernel-prefix.py <environment-x.yml> <environment-x-lock.yml>")
    env_file, lock_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    if not lock_file.is_file():
        fail(f"{env_file.name} has no lock at {lock_file}. Run scripts/lock-kernel-envs.py.")

    locks = lock_module()
    if json.loads(lock_file.read_text())["metadata"]["content_hash"].get(PLATFORM) \
            != locks.content_hash(env_file):
        fail(f"{lock_file.name} was made from a different {env_file.name}. "
             "Run scripts/lock-kernel-envs.py to lock it again.")

    declared = yaml.safe_load(env_file.read_text())
    name = declared["name"]
    # The same reading jupyterlite-xeus makes of an environment file.
    specs = [d for d in declared.get("dependencies", []) if isinstance(d, str)]
    channels = declared.get("channels", [])
    if not specs or not channels:
        fail(f"{env_file.name} declares no dependencies or no channels")

    micromamba = shutil.which("micromamba")
    if not micromamba:
        fail("micromamba is not on PATH")
    prefix = PREFIX_ROOT / "envs" / name
    shutil.rmtree(prefix, ignore_errors=True)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    if os.path.realpath(PREFIX_ROOT) != str(PREFIX_ROOT):
        print(f"create-kernel-prefix: WARNING {PREFIX_ROOT} resolves to "
              f"{os.path.realpath(PREFIX_ROOT)}, so this build's kernel binaries "
              "will not match a Linux build byte for byte.", file=sys.stderr)

    # The flags jupyterlite-xeus uses for its own install, less the solve:
    # micromamba installs exactly the files the lock names, and refuses one
    # whose sha256 differs from the lock's.
    subprocess.run(
        [
            micromamba, "create", "--yes", "--no-pyc",
            "--prefix", str(prefix),
            "--relocate-prefix", "",
            f"--platform={PLATFORM}",
            "--file", str(lock_file),
        ],
        check=True,
        stdout=sys.stderr,
    )

    # Each package record's `channel` reaches the browser through
    # empack_env_meta.json, where mambajs matches it against the channel list.
    # micromamba 2.10 records a package from conda-forge with an empty channel,
    # and one from emscripten-forge with its subdir on the end, and neither
    # matches, so the browser logged a "Failed to detect channel" warning for
    # each. Record the channel's own URL, which is the package URL without its
    # subdir and file name: what the kernels shipped with before.
    for record_path in sorted((prefix / "conda-meta").glob("*.json")):
        record = json.loads(record_path.read_text())
        url = record.get("url", "")
        channel = url.rsplit("/", 2)[0] if url.count("/") >= 4 else ""
        if channel and record.get("channel") != channel:
            record["channel"] = channel
            record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    # jupyterlite-xeus reads the specs and the channels from the history, and
    # an install from a lock records neither. Record the declared ones.
    channel_args = " ".join(f"-c {c}" for c in channels)
    history_path = prefix / "conda-meta" / "history"
    lines = [line for line in history_path.read_text().splitlines(keepends=True)
             if not line.startswith("# update specs:")]
    lines.append(f"# cmd: chickadee-create-kernel-prefix {channel_args}\n")
    lines.append(f"# update specs: {specs!r}\n")
    history_path.write_text("".join(lines))
    print(prefix)


if __name__ == "__main__":
    main()

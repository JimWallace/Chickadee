#!/usr/bin/env python3
"""Report Swift package pins that a `swift package update` would move.

WHY THIS EXISTS. Dependabot watches both Swift package graphs (`/` and
`/wasm`) in .github/dependabot.yml, but its Swift toolchain lags ours. Since
the manifests moved to `swift-tools-version:6.4`, every Dependabot Swift run
has failed with "package 'repo' is using Swift tools version 6.4.0 but the
installed version is 6.3.1", and no Swift update PR opened from June to
November 2026. Nineteen packages, swift-nio-ssl, swift-certificates and Vapor
among them, fell behind with nothing in the repository saying so.

This script asks the toolchain we actually build with. For each package
directory it runs `swift package update --dry-run`, which resolves the
manifest's requirements against the remotes without writing anything, and
compares each answer with the version pinned in that directory's
Package.resolved. A pin held by revision (a fork) or a local package has no
version to compare and is skipped.

The dry run reports changes against the WORKSPACE STATE in the scratch
directory (`.build`), not against Package.resolved. In a checkout whose
`.build` already holds newer versions, a stale Package.resolved pin is simply
not listed, and the check would read "current". So each resolve runs in a new,
empty `--scratch-path`, where every package is listed with the version it
resolves to.

Exit status: 0 when every versioned pin is current, 1 when one or more would
move, 2 when the check itself could not run (a failed resolve, a missing
Package.resolved). Red is a notification, not a broken build: the workflow
that runs this is off the pull request path.

    scripts/check-swift-currency.py            check / and wasm/
    scripts/check-swift-currency.py DIR...     check the named directories
    scripts/check-swift-currency.py --self-test
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# A dry-run line names one package and the version it would resolve to. An
# empty scratch directory lists each package as added, `+ swift-nio 2.104.0`.
# A workspace that already has a package lists a change as
# `~ swift-nio 2.104.0 -> swift-nio 2.105.0`; the version that counts is the one
# after the arrow. SwiftPM prints `unversioned` for the root package and a
# revision for a branch or revision requirement; neither is a version, so
# neither matches.
DRY_RUN_LINE = (
    r"^[+~] (?:\S+ \S+ -> )?(?P<name>\S+) (?P<version>\d+\.\d+\.\d+\S*)$"
)

RESOLVE_TIMEOUT_SECONDS = 900


def pinned_versions(resolved_text: str) -> dict[str, str]:
    """Each pin's identity mapped to its version; revision-only pins are left out."""
    pins = json.loads(resolved_text).get("pins", [])
    return {
        pin["identity"]: pin["state"]["version"]
        for pin in pins
        if pin.get("state", {}).get("version")
    }


def proposed_versions(dry_run_text: str) -> dict[str, str]:
    """Each package the dry run resolved, mapped to the version it chose."""
    pattern = re.compile(DRY_RUN_LINE)
    found: dict[str, str] = {}
    for line in dry_run_text.splitlines():
        match = pattern.match(line.strip())
        if match:
            found[match["name"]] = match["version"]
    return found


def stale_pins(resolved_text: str, dry_run_text: str) -> list[tuple[str, str, str]]:
    """(identity, pinned, proposed) for each pin the dry run would move."""
    pinned = pinned_versions(resolved_text)
    proposed = proposed_versions(dry_run_text)
    return sorted(
        (name, pinned[name], version)
        for name, version in proposed.items()
        if name in pinned and pinned[name] != version
    )


def check_directory(directory: Path) -> tuple[int, str]:
    resolved = directory / "Package.resolved"
    if not resolved.is_file():
        return 2, f"{directory}: no Package.resolved to compare with"
    try:
        with tempfile.TemporaryDirectory(prefix="swift-currency-") as scratch:
            result = subprocess.run(
                ["swift", "package", "--scratch-path", scratch, "update", "--dry-run"],
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=RESOLVE_TIMEOUT_SECONDS,
                check=False,
            )
    except subprocess.TimeoutExpired:
        return 2, f"{directory}: swift package update --dry-run took over {RESOLVE_TIMEOUT_SECONDS}s"
    if result.returncode != 0:
        tail = "\n".join((result.stdout + result.stderr).splitlines()[-15:])
        return 2, f"{directory}: swift package update --dry-run failed\n{tail}"
    stale = stale_pins(resolved.read_text(), result.stdout + result.stderr)
    if not stale:
        return 0, f"{directory}: every versioned pin is current"
    lines = [f"{directory}: {len(stale)} pin(s) behind"]
    lines += [f"  {name}: {old} -> {new}" for name, old, new in stale]
    return 1, "\n".join(lines)


def self_test() -> int:
    """Prove the comparator reports a difference, and reports nothing when there is none."""
    resolved = json.dumps(
        {
            "pins": [
                {"identity": "vapor", "state": {"revision": "a", "version": "4.122.2"}},
                {"identity": "swift-nio", "state": {"revision": "b", "version": "2.104.0"}},
                {"identity": "a-fork", "state": {"revision": "c"}},
            ]
        }
    )
    dry_run = "\n".join(
        [
            "[Dry-run] 4 dependencies would change:",
            "+ vapor 4.122.3",
            "+ swift-nio 2.104.0",
            "+ a-fork 1.9.0",
            "+ chickadee unversioned",
        ]
    )
    failures = []
    if stale_pins(resolved, dry_run) != [("vapor", "4.122.2", "4.122.3")]:
        failures.append(f"expected only vapor to be stale, got {stale_pins(resolved, dry_run)}")
    workspace_form = "~ vapor 4.122.2 -> vapor 4.122.3"
    if stale_pins(resolved, workspace_form) != [("vapor", "4.122.2", "4.122.3")]:
        failures.append(f"the `~ old -> new` form was not read, got {stale_pins(resolved, workspace_form)}")
    current = dry_run.replace("4.122.3", "4.122.2")
    if stale_pins(resolved, current):
        failures.append(f"expected nothing stale, got {stale_pins(resolved, current)}")
    if stale_pins(resolved, ""):
        failures.append("an empty dry run must report nothing stale")
    if failures:
        for failure in failures:
            print(f"check-swift-currency self-test: {failure}", file=sys.stderr)
        return 1
    print("check-swift-currency self-test: OK (a moved pin is reported; a current one is not)")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    root = Path(__file__).resolve().parent.parent
    directories = [Path(arg) for arg in argv] or [root, root / "wasm"]
    worst = 0
    for directory in directories:
        status, report = check_directory(directory)
        print(report)
        worst = max(worst, status)
    if worst == 1:
        print(
            "\ncheck-swift-currency: pins are behind. Run `swift package update` in each"
            " directory named above, build and test, and open a PR. Land a package that"
            " .github/dependabot.yml says to keep separate (the SwiftLint plugin,"
            " JavaScriptKit) as its own PR."
        )
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

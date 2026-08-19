#!/usr/bin/env python3
"""Apply one recorded mutation, run the suite, and say whether it dies.

WHY THIS EXISTS. A mutation report is a list of QUESTIONS, and the only honest
way to answer one is to make the change and watch what happens. Reasoning about
it from the source does not work -- measured, twice, in opposite directions:

  * A triage pass that read Muter's list and reasoned about the code called four
    already-covered sites "holes" and one unkillable mutant "the highest-value
    finding here". Roughly half the list was wrong.
  * The same pass then mutated whole `||` chains where Muter mutates ONE
    connector, which is a stronger change, and so called three REAL gaps
    covered. Being careful in the wrong direction is just as wrong.

So this runs the experiment instead, and it is meant to be run TWICE per
survivor:

    before writing anything   -> expect SURVIVED. Anything else means the
                                 finding is stale (the code moved) or was never
                                 real, and no test should be written for it.
    after writing the test    -> expect KILLED, and by the test you just added.

That second run is this repository's existing rule -- a check never seen to fail
is not a check (scripts/check-guards.sh) -- applied to a unit test.

USAGE

    Tools/mutation/verify-survivor.py --run-record MutationReports/<file>.json \\
        --file Sources/Core/JSONValue.swift --line 57 --operator ChangeLogicalConnector

    Tools/mutation/verify-survivor.py --all --run-record <file>.json   # every survivor

The mutation comes from the run record's `mutations` field, so what runs here is
what Muter actually inserted -- not a reconstruction. A survivor whose record
carries no mutation cannot be verified mechanically and is reported as such
rather than approximated.

EXIT CODES
    0  the mutant SURVIVED  (a real gap, or an equivalent mutant)
    1  the mutant was KILLED
    2  could not verify (no recorded mutation, source drifted, build failure)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

# Tools/mutation/verify-survivor.py -> three levels up is the repo root.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG = os.path.join(REPO, "Tools/mutation/config.json")


def load_test_command() -> list[str]:
    """The sweep's own test command, so a verdict here means the same thing.

    Read from config rather than restated: a verifier running a different suite
    than the sweep would answer a different question and look like it answered
    this one.
    """
    with open(CONFIG) as fh:
        return ["swift"] + json.load(fh)["testArgs"]


def survivors_from(record_path: str) -> list[dict]:
    with open(record_path) as fh:
        return json.load(fh).get("survivors", [])


def pick(survivors: list[dict], path: str, line: int, operator: str | None) -> list[dict]:
    return [
        s
        for s in survivors
        if s["file"] == path
        and s["line"] == line
        and (operator is None or s["operator"] == operator)
    ]


def apply_mutation(source_path: str, line: int, mutated: str) -> str | None:
    """Replace the statement at `line` with the mutation. Returns the original.

    Muter records the mutated STATEMENT, so the replacement is line-oriented and
    only safe when the target line still looks like what was mutated. Returning
    None rather than editing on a mismatch is deliberate: a verifier that
    silently mutates the wrong line reports a verdict about code nobody asked
    about.
    """
    with open(source_path) as fh:
        lines = fh.readlines()
    if not 1 <= line <= len(lines):
        return None
    original = "".join(lines)
    if not mutated.strip():
        # RemoveSideEffects: the mutation IS the absence of the statement.
        del lines[line - 1]
    else:
        indent = re.match(r"\s*", lines[line - 1]).group(0)
        body = "\n".join(indent + ln.lstrip() if ln.strip() else ln for ln in mutated.splitlines())
        lines[line - 1] = body + "\n"
    with open(source_path, "w") as fh:
        fh.writelines(lines)
    return original


def run_suite(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=7200)
    return proc.returncode, proc.stdout + proc.stderr


def failing_suites(output: str) -> list[str]:
    return sorted(
        {
            ln.split("Suite ")[1].split(" failed")[0]
            for ln in output.splitlines()
            if "Suite " in ln and " failed" in ln
        }
    )


def verify_one(survivor: dict, cmd: list[str], quiet: bool) -> int:
    path = survivor["file"]
    line = survivor["line"]
    label = f"{path}:{line} {survivor['operator']}"
    muts = survivor.get("mutations") or []
    if not muts:
        print(f"UNVERIFIABLE  {label}")
        print("    No mutation was recorded for this survivor, so it cannot be")
        print("    reproduced mechanically. Confirm it by hand before acting on it.")
        return 2

    source_path = os.path.join(REPO, path)
    if not os.path.isfile(source_path):
        print(f"UNVERIFIABLE  {label}\n    {path} no longer exists; the finding is stale.")
        return 2

    worst = 1
    for i, mut in enumerate(muts, 1):
        tag = f"{label}" + (f"  [candidate {i} of {len(muts)}]" if len(muts) > 1 else "")
        shown = " ".join(mut["mutated"].split())[:150] or "<statement deleted>"
        backup = apply_mutation(source_path, line, mut["mutated"])
        if backup is None:
            print(f"UNVERIFIABLE  {tag}\n    Line {line} is out of range; the source has moved.")
            worst = max(worst, 2)
            continue
        try:
            code, output = run_suite(cmd)
        finally:
            with open(source_path, "w") as fh:
                fh.write(backup)
        if code == 0:
            print(f"SURVIVED      {tag}")
            print(f"    applied: {shown}")
            print("    Nothing in the suite could tell the difference. Either a real")
            print("    gap, or an equivalent mutant -- decide which, and record why.")
            worst = 0
        else:
            suites = failing_suites(output)
            print(f"KILLED        {tag}")
            print(f"    failed: {', '.join(suites) if suites else 'suite failed'}")
            if not quiet:
                print("    Already covered. Do not write a test for this one.")
            worst = min(worst, 1) if worst != 0 else 0
    return worst


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-record", required=True, help="A MutationReports/<date>-run<id>.json")
    ap.add_argument("--file", help="Survivor's file, repo-relative")
    ap.add_argument("--line", type=int, help="Survivor's line")
    ap.add_argument("--operator", help="Muter operator name; omit to take every operator on that line")
    ap.add_argument("--all", action="store_true", help="Verify every survivor in the record")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    survivors = survivors_from(args.run_record)
    if args.all:
        targets = survivors
    else:
        if not args.file or args.line is None:
            ap.error("--file and --line are required unless --all is given")
        targets = pick(survivors, args.file, args.line, args.operator)
        if not targets:
            print(f"No survivor at {args.file}:{args.line} in {args.run_record}.")
            print("Check the file path is repo-relative and the line matches the record.")
            return 2

    if not shutil.which("swift"):
        print("swift is not on PATH.")
        return 2

    cmd = load_test_command()
    print(f"Suite: {' '.join(cmd)}\n")
    verdicts = [verify_one(t, cmd, args.quiet) for t in targets]
    if len(verdicts) > 1:
        n = {0: 0, 1: 0, 2: 0}
        for v in verdicts:
            n[v] += 1
        print(f"\n{n[0]} survived, {n[1]} killed, {n[2]} unverifiable, of {len(verdicts)}.")
    return 0 if 0 in verdicts else (2 if all(v == 2 for v in verdicts) else 1)


if __name__ == "__main__":
    sys.exit(main())

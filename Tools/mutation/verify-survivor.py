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

VERDICTS
    SURVIVED      nothing detects the change -- a real gap, or an equivalent mutant
    KILLED        the suite detects it, and the line names which suite
    INERT         Muter re-emitted the original; there is no change to detect
    UNVERIFIABLE  the experiment could not be run (see the message)

EXIT CODES
    0  the mutant SURVIVED  (a real gap, or an equivalent mutant)
    1  the mutant was KILLED
    2  could not verify (no recorded mutation, source drifted, build failure,
       or the recorded mutation is INERT)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
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


def whole_line_is_the_statement(current: str, mutated: str) -> bool:
    """Whether replacing the whole of `current` with `mutated` is faithful.

    Only true when the line holds exactly the statement that was mutated. The
    counter-examples are the common ones, not exotica: `case .equals: return lhs
    == value` loses its `case` label, a continuation line like `|| $0.signal ==
    .gradeJumpPercent` gets the whole expression pasted beside the half already
    above it, and a mutation whose recorded text opens with `//` comments out
    whatever followed on the line.
    """
    if not mutated.strip() or len(mutated.splitlines()) != 1:
        return False
    cur, mut = " ".join(current.split()), " ".join(mutated.split())
    if mut.startswith("//"):
        return False
    # One token differs (the mutated operator) and nothing else moves, so the
    # token count and the punctuation that frames a statement must both match.
    return len(cur.split()) == len(mut.split()) and cur.count(":") == mut.count(":")


def strip_duplicated_trailing_comment(body: str) -> str:
    """Drop the copy of the leading comment Muter re-emits after the statement.

    MEASURED, not assumed. For a `case` body that opens with a comment, Muter's
    schema branches come out as [comment][statements][THE SAME COMMENT AGAIN].
    That trailing copy exists nowhere in the source file, so the recorded text
    is not a contiguous substring of it and an exact search finds nothing: 14 of
    run 32265903112's 110 candidates were unverifiable for this and no other
    reason. Removing it makes all 14 match exactly once.

    Applied to the mutation as well as the original, so the replacement puts
    back what was there rather than injecting a second comment block.

    The check is deliberately narrow -- the trailing run must be the leading run,
    line for line -- because a body that genuinely ends in a comment is ordinary
    and must not be truncated.
    """
    lines = body.split("\n")
    lead = 0
    while lead < len(lines) and lines[lead].strip().startswith("//"):
        lead += 1
    if lead == 0 or lead >= len(lines) - lead:
        return body
    if [l.strip() for l in lines[:lead]] != [l.strip() for l in lines[-lead:]]:
        return body
    return "\n".join(lines[:-lead]).rstrip()


def locate_unique(text: str, needle: str, line: int) -> int | None:
    """Offset of the one occurrence of `needle` this record means, or None.

    Content alone cannot always identify a mutation site: `let pairs = o.sorted
    { $0.key < $1.key }` is byte-identical in all four literal renderers of
    JSONValue.swift. Muter's line is unreliable on its own, but it is a fine
    DISCRIMINATOR among exact content matches -- so it is used only to choose
    between them, and only when one of them begins exactly at that line.

    No nearest-match heuristic: picking the closest would mean mutating R's
    renderer while reporting a verdict about Python's. Measured across the run's
    three ambiguous candidates, the exact-line rule resolves all three.
    """
    first = text.find(needle)
    if first < 0:
        return None
    if text.find(needle, first + 1) < 0:
        return first
    offset, matches = first, []
    while offset >= 0:
        matches.append(offset)
        offset = text.find(needle, offset + 1)
    exact = [m for m in matches if text[:m].count("\n") + 1 == line]
    return exact[0] if len(exact) == 1 else None


def apply_mutation(source_path: str, line: int, mutated: str, original: str | None) -> str | None:
    """Apply the mutation to the file, returning the file's previous contents.

    PREFER CONTENT OVER POSITION. When the run record carries the schema's
    `original` -- the trailing `else` of Muter's chain -- the edit is an exact
    textual swap and Muter's line number is not consulted at all. That matters
    because those line numbers are known-wrong: `report.py` says so in the issue
    body it writes, and measured against run 32255707345 only 15 of 84
    candidates had the mutated statement actually occupying the reported line.

    Returning None rather than editing is the whole safety property here. A
    mis-applied mutation does not fail honestly -- it fails to COMPILE, the
    suite goes red, and the caller reads that as `KILLED`, which the protocol
    spells "already covered, do not write a test". Silently discarding a real
    gap is the one outcome mutation testing exists to prevent.
    """
    with open(source_path) as fh:
        text = fh.read()

    if original is not None and original.strip():
        want = strip_duplicated_trailing_comment(original)
        repl = strip_duplicated_trailing_comment(mutated)
        at = locate_unique(text, want, line)
        if at is None:
            return None
        with open(source_path, "w") as fh:
            fh.write(text[:at] + repl + text[at + len(want):])
        return text

    lines = text.splitlines(keepends=True)
    if not 1 <= line <= len(lines):
        return None
    if not mutated.strip():
        # RemoveSideEffects: the mutation IS the absence of the statement. Only
        # safe positionally when the record names the deleted statement's own
        # line, which without an `original` cannot be confirmed -- so this is
        # allowed only when the line is a single self-contained statement.
        if lines[line - 1].strip().endswith(("{", "}")):
            return None
        del lines[line - 1]
    elif whole_line_is_the_statement(lines[line - 1], mutated):
        indent = re.match(r"\s*", lines[line - 1]).group(0)
        lines[line - 1] = indent + mutated.strip() + "\n"
    else:
        return None
    with open(source_path, "w") as fh:
        fh.writelines(lines)
    return text


def run_suite(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=7200)
    return proc.returncode, proc.stdout + proc.stderr


def _restore_on_signal(source_path: str, backup: str) -> None:
    """Put the file back if this process is killed while a mutation is applied.

    A suite run here is minutes long, so Ctrl-C during one is ordinary. Without
    this the interrupt leaves a mutated source in the working tree, which then
    looks like an edit the author made -- and the mutations are by construction
    the kind that still compile and still pass.
    """

    def handler(signum, _frame):
        with open(source_path, "w") as fh:
            fh.write(backup)
        sys.exit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, handler)


def tests_actually_ran(output: str) -> bool:
    """Whether the suite ran at all, as opposed to failing to build.

    `swift test` exits non-zero for both, and the difference is the difference
    between "a test caught this" and "this is not valid Swift". Reading the
    second as the first is how a mis-applied mutation reports `KILLED` and a
    real gap gets closed as already-covered.
    """
    return "Test run with" in output or "Executed" in output


def failing_suites(output: str) -> list[str]:
    return sorted(
        {
            ln.split("Suite ")[1].split(" failed")[0]
            for ln in output.splitlines()
            if "Suite " in ln and " failed" in ln
        }
    )


def is_inert(mut: dict) -> bool:
    """True when Muter's "mutation" is the original statement re-emitted.

    `Tools/mutation/report.py` quarantines these out of a run's survivor list
    (nine of the 75 in run 32265903112 were this), but a record produced before
    that filter existed still carries them, and `--file/--line` reads the record
    directly. Without this check the verifier applies an unchanged file, runs the
    whole suite for two minutes, and reports SURVIVED -- which reads as "nothing
    detects this change" when there was no change to detect. That is precisely
    the answer that gets a test written for nothing.
    """
    original = mut.get("original")
    if original is None:
        return False
    return " ".join(mut["mutated"].split()) == " ".join(original.split())


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
        if is_inert(mut):
            print(f"INERT         {tag}")
            print("    Muter's mutated text is the original, modulo whitespace, so there")
            print("    is no change for a test to detect. `SwapTernary` does this: it")
            print("    re-emits `cond ? a : b` with the branches unswapped. Not a gap and")
            print("    not an equivalent mutant either -- there is nothing here at all.")
            print("    report.py quarantines these; a record written before it did still")
            print("    carries them, which is why this check is here too.")
            worst = max(worst, 2)
            continue
        backup = apply_mutation(source_path, line, mut["mutated"], mut.get("original"))
        if backup is not None:
            _restore_on_signal(source_path, backup)
        if backup is None:
            print(f"UNVERIFIABLE  {tag}")
            if mut.get("original"):
                print("    The recorded original does not appear exactly once in the file;")
                print("    the source has moved since the sweep. Re-run the sweep.")
            else:
                print("    This record carries no `original`, and the mutated statement is")
                print(f"    not what line {line} holds, so it cannot be applied faithfully.")
                print("    Re-run the sweep to record originals; do NOT edit by hand.")
            worst = max(worst, 2)
            continue
        try:
            code, output = run_suite(cmd)
        finally:
            with open(source_path, "w") as fh:
                fh.write(backup)
        if code != 0 and not tests_actually_ran(output):
            print(f"UNVERIFIABLE  {tag}")
            print(f"    applied: {shown}")
            print("    The mutated source did not build, so no test graded it. This is")
            print("    a bad mutation record or a moved source -- NOT a kill.")
            worst = max(worst, 2)
            continue
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

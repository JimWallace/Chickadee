#!/usr/bin/env python3
"""Read every run in MutationReports/ and print the trend.

WHAT THIS IS FOR. One mutation score answers nothing: 69% is neither good nor
bad in isolation, and the pilot's own conclusion was that chasing a percentage
means writing tests for inputs that cannot occur. What a series answers is the
question worth asking -- is the suite getting better at telling the difference
when the source changes, and which holes have survived every attempt so far.

THREE THINGS THIS REFUSES TO DO SILENTLY, each of which would make the trend
lie in the direction of good news:

  * COMPARE ACROSS CONFIGURATIONS. The score depends on what was mutated
    (`include`), how mutants were graded (`testArgs`) and which Muter built
    them. Change any of those and the next number is a different measurement
    wearing the same units. Runs carry a fingerprint; a change marks the row
    and splits the persistent-survivor set, because a survivor cannot be
    "still surviving" across a run that never mutated its file.

  * COUNT A PARTIAL SWEEP AS A CLEAN ONE. The sweep is sharded ten ways and a
    shard that dies uploads nothing. Fewer shards means fewer mutants means a
    smaller survivor count -- which reads exactly like progress. Every row
    shows shards covered, and an incomplete run is marked and excluded from
    the persistent set.

  * IDENTIFY A SURVIVOR BY LINE NUMBER. Line numbers move whenever anything
    above them is edited, so a line-keyed backlog empties itself on the first
    unrelated commit and reports the holes as fixed. Survivors are keyed by
    (file, operator, source text); the line is display only.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REPORTS_DIR = "MutationReports"


def score(killed: int, survived: int) -> float | None:
    """Killed as a fraction of mutants that ran. None when nothing ran.

    Recomputed from counts rather than averaged from the shards' own
    percentages: shards differ in mutant count, so the mean of ten percentages
    is not the percentage of the whole.
    """
    total = killed + survived
    return None if total == 0 else killed / total


def survivor_key(s: dict) -> tuple[str, str, str]:
    """Identity of a survivor across runs. Deliberately excludes the line."""
    return (s.get("file", ""), s.get("operator", ""), " ".join(s.get("source", "").split()))


def fingerprint(run: dict) -> tuple:
    """What must match for two runs to be comparable."""
    c = run.get("config", {})
    return (
        c.get("muterRef"),
        c.get("patchHash"),
        c.get("configHash"),
        c.get("swift"),
    )


def load_runs(directory: str) -> list[dict]:
    """Every *.json in the reports directory, oldest first.

    A malformed file is a hard error rather than a skip: silently dropping a
    run shortens the series, and a shorter series makes the persistent set
    smaller -- the same false good news the shard check exists to catch.
    """
    if not os.path.isdir(directory):
        return []
    runs = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path) as fh:
                run = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            raise SystemExit(f"{path}: unreadable run report ({exc})")
        run.setdefault("date", os.path.splitext(name)[0])
        run["_file"] = name
        runs.append(run)
    # (date, filename): a record is keyed by date AND run id, because a manual
    # dispatch beside the Tuesday schedule puts two sweeps on one day. Sorting
    # on the date alone would order those two unstably between invocations.
    runs.sort(key=lambda r: (r.get("date", ""), r.get("_file", "")))
    return runs


def is_complete(run: dict) -> bool:
    expected, reported = run.get("shardsExpected"), run.get("shardsReported")
    return bool(expected) and reported == expected


def persistent_survivors(runs: list[dict]) -> list[dict]:
    """Survivors present in EVERY comparable, complete run.

    Restricted to the newest fingerprint: a run under a different config may
    never have mutated the file at all, and absence there is not evidence a
    mutant died. Incomplete runs are excluded for the same reason.
    """
    usable = [r for r in runs if is_complete(r)]
    if not usable:
        return []
    current = fingerprint(usable[-1])
    usable = [r for r in usable if fingerprint(r) == current]
    if not usable:
        return []

    common = set(survivor_key(s) for s in usable[0].get("survivors", []))
    for run in usable[1:]:
        common &= set(survivor_key(s) for s in run.get("survivors", []))

    # Report each survivor as the LATEST run saw it: the line number in an
    # older run is stale by definition, and triage happens against today's
    # source. Ordered by file then line, which is the order someone reads them.
    latest = {survivor_key(s): s for s in usable[-1].get("survivors", [])}
    found = [latest[k] for k in common if k in latest]
    return sorted(found, key=lambda s: (s.get("file", ""), s.get("line", 0)))


def format_table(runs: list[dict]) -> str:
    rows = [
        "| date       | shards | mutants | killed | survivors | score | ",
        "|------------|--------|---------|--------|-----------|-------|",
    ]
    previous = None
    for run in runs:
        killed, survived = run.get("killed", 0), run.get("survived", 0)
        pct = score(killed, survived)
        expected = run.get("shardsExpected") or "?"
        reported = run.get("shardsReported") or 0
        shards = f"{reported}/{expected}"

        flags = []
        if not is_complete(run):
            flags.append("PARTIAL")
        if previous is not None and fingerprint(run) != previous:
            flags.append("CONFIG CHANGED")
        previous = fingerprint(run)

        rows.append(
            f"| {run.get('date', '?'):<10} | {shards:>6} | {killed + survived:>7} "
            f"| {killed:>6} | {survived:>9} | "
            f"{'n/a' if pct is None else format(pct * 100, '.1f') + '%':>5} | "
            + (" ".join(flags))
        )
    return "\n".join(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default=REPORTS_DIR, help=f"reports directory (default {REPORTS_DIR})")
    args = parser.parse_args(argv)

    runs = load_runs(args.dir)
    if not runs:
        print(f"No runs in {args.dir}/. The weekly sweep writes one file per run.")
        return 0

    print(format_table(runs))
    print()

    latest = runs[-1]
    if not is_complete(latest):
        print(
            f"The most recent run covered {latest.get('shardsReported')} of "
            f"{latest.get('shardsExpected')} shards. Its totals are LOWER because less\n"
            "was mutated, not because fewer mutants survived. Do not read it as progress."
        )
        print()

    persistent = persistent_survivors(runs)
    comparable = [r for r in runs if is_complete(r) and fingerprint(r) == fingerprint(runs[-1])]
    if len(comparable) < 2:
        print(
            "Persistent backlog needs at least two complete runs on one configuration; "
            f"there {'is' if len(comparable) == 1 else 'are'} {len(comparable)}."
        )
        return 0

    print(f"### Survived every one of the last {len(comparable)} comparable runs ({len(persistent)})")
    print()
    print(
        "This is the standing backlog. Expect a good fraction to be EQUIVALENT MUTANTS --\n"
        "unkillable by construction, because no input reaching that code can tell the\n"
        "difference. Those are closed with a reason, not with a test. A survivor is a\n"
        "question; 'correctly, no test' is a legitimate answer."
    )
    print()
    current_file = None
    for s in persistent:
        if s.get("file") != current_file:
            current_file = s.get("file")
            print(f"\n**{current_file}**")
        src = s.get("source", "")
        print(f"  L{s.get('line')} {s.get('operator')}" + (f" — {src}" if src else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

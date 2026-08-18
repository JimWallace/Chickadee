#!/usr/bin/env python3
"""Merge one sweep's shard reports into a single durable run record.

Usage: merge-run.py <shards-dir> <out.json> [date]

WHY THIS EXISTS. The sweep's output was, until this, entirely perishable: ten
GitHub artifacts that expire and one issue body written as prose. Neither can
be read as a series, so there was no way to answer whether the suite is
improving -- only what one Tuesday looked like. This writes the one artefact a
trend can be built on, and it is committed to the repo rather than uploaded,
because the point of a trend is that it outlives the retention window.

THE ONE RULE HERE: a shard that produced nothing must never look like a shard
that found nothing. Both contribute zero survivors. `shardsReported` versus
`shardsExpected` is what tells them apart, and Tools/mutation/trend.py refuses
to read a run where they differ as a comparable data point.
"""

from __future__ import annotations

import json
import os
import sys


def load(path: str) -> dict | None:
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def merge(shards_dir: str, expected: int, date: str) -> dict:
    killed = survived = 0
    survivors: list[dict] = []
    phantoms = 0
    seen: set[int] = set()
    env: dict = {}

    for entry in sorted(os.listdir(shards_dir)) if os.path.isdir(shards_dir) else []:
        summary = load(os.path.join(shards_dir, entry, "summary.json"))
        if summary is None:
            continue
        # An artifact can exist and still carry no outcomes -- the shard died
        # after the directory was created. Counting it as covered is the same
        # lie in smaller print, so a shard counts only if it reported mutants.
        if summary.get("killed", 0) + summary.get("survived", 0) == 0:
            continue
        if summary.get("shard") is not None:
            seen.add(summary["shard"])
        killed += summary.get("killed", 0)
        survived += summary.get("survived", 0)
        phantoms += len(summary.get("phantoms", []))
        survivors.extend(summary.get("survivors", []))
        env = env or load(os.path.join(shards_dir, entry, "env.json")) or {}

    return {
        "date": date,
        "shardsExpected": expected,
        "shardsReported": len(seen),
        "killed": killed,
        "survived": survived,
        "phantomsFiltered": phantoms,
        "config": {
            "muterRef": env.get("muterRef"),
            "patchHash": env.get("patchHash"),
            "configHash": env.get("configHash"),
            "swift": env.get("swift"),
        },
        "commit": env.get("commit"),
        "survivors": sorted(
            survivors, key=lambda s: (s.get("file", ""), s.get("line", 0), s.get("operator", ""))
        ),
    }


def main() -> int:
    shards_dir, out_path = sys.argv[1], sys.argv[2]
    date = sys.argv[3] if len(sys.argv) > 3 else None
    if not date:
        raise SystemExit("a date is required; the run record is keyed by it")

    with open("Tools/mutation/config.json") as fh:
        expected = json.load(fh)["shardCount"]

    run = merge(shards_dir, expected, date)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as fh:
        json.dump(run, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(
        f"{out_path}: {run['killed']} killed, {run['survived']} survived across "
        f"{run['shardsReported']}/{run['shardsExpected']} shards"
    )
    if run["shardsReported"] == 0:
        # Writing a record of nothing would put a permanent 0% in the series.
        print("No shard reported any mutant. Not a measurement; refusing to record it.", file=sys.stderr)
        os.remove(out_path)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

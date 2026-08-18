#!/usr/bin/env python3
"""Turn a Muter plain-format run into a triage report, with PHANTOM MUTANTS removed.

Why this exists rather than reading Muter's report directly: **Muter reports
mutants it never inserted, and they always read as "survived".**

Measured 2026-08-18 on Sources/RunnerCore/SuiteExecution.swift. Muter reported
four RemoveSideEffects mutants -- lines 82, 86, 89, 90 -- and called 82, 86 and
90 survivors. But the mutated copy contains only THREE schemata for that
operator, at 86, 89 and 90. There is no switch for line 82. Line 82 is
`onEvent(.missingScript(...))`, it is covered by an existing test, and
hand-deleting it fails the suite in 0.002s. It was never mutated, so the
unmutated binary ran, passed, and was recorded as a survivor.

That is the phantom-mutant failure mode of muter#308, and it is the dangerous
one: a phantom is indistinguishable from a real hole in the report, and acting
on it sends someone to write a test that already exists -- the "confident wrong
answer" this whole exercise exists to catch.

The fix: the MUTATED PROJECT COPY is the ground truth. Every genuinely inserted
schema is guarded by `ProcessInfo.processInfo.environment["<id>"]`, where the id
is `{fileStem}_{operator}_{line}_{column}_{utf8Offset}`. A reported survivor
whose (file, operator, line) has no matching guard was never inserted. We list
those separately as phantoms and keep them out of the survivor list, so nobody
triages a mutant that does not exist.

Note the positions themselves are accurate -- 86, 89 and 90 matched exactly.
Only the phantom carries a bogus line.
"""

from __future__ import annotations

import json
import os
import re
import sys

ROW = re.compile(r"^(\S+\.swift):(\d+)\s+(\S+)\s+mutant (survived|killed)", re.M)
SCHEMA_ID = re.compile(r'environment\["([A-Za-z0-9_]+?)_([A-Za-z]+)_(\d+)_(\d+)_(\d+)"\]')
SCORE = re.compile(r"Mutation Score of Test Suite:\s*(\d+)%")
TOOK = re.compile(r"Muter took\s+(\S+)")


def harvest_true_positions(mutated_root: str) -> dict[tuple[str, str], list[int]]:
    """Map (file stem, operator) -> sorted true line numbers, from the copy."""
    found: dict[tuple[str, str], set[int]] = {}
    if not mutated_root or not os.path.isdir(mutated_root):
        return {}
    for root, _dirs, files in os.walk(mutated_root):
        if "/.build" in root:
            continue
        for name in files:
            if not name.endswith(".swift"):
                continue
            try:
                text = open(os.path.join(root, name), errors="ignore").read()
            except OSError:
                continue
            for stem, operator, line, _col, _off in SCHEMA_ID.findall(text):
                found.setdefault((stem, operator), set()).add(int(line))
    return {k: sorted(v) for k, v in found.items()}


def repo_path(base: str, cache: dict[str, str]) -> str:
    if base in cache:
        return cache[base]
    for root, _dirs, files in os.walk("Sources"):
        if base in files:
            cache[base] = os.path.join(root, base)
            return cache[base]
    cache[base] = base
    return base


def source_line(path: str, lineno: int) -> str:
    try:
        with open(path, errors="ignore") as fh:
            for i, line in enumerate(fh, 1):
                if i == lineno:
                    return line.strip()
    except OSError:
        pass
    return ""


def main() -> int:
    raw_path, out_dir, label, mutated_root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    text = open(raw_path, errors="ignore").read()

    rows = [(m.group(1), int(m.group(2)), m.group(3), m.group(4)) for m in ROW.finditer(text)]
    survived = [r for r in rows if r[3] == "survived"]
    killed = [r for r in rows if r[3] == "killed"]

    truth = harvest_true_positions(mutated_root)
    cache: dict[str, str] = {}

    # A reported survivor is only real if a schema was actually inserted for it.
    # Compare against the guards harvested from the mutated copy; anything with
    # no guard was never mutated, so its "survival" means nothing.
    resolved, phantoms = [], []
    for base, reported, operator, _ in survived:
        stem = base[:-6] if base.endswith(".swift") else base
        candidates = truth.get((stem, operator), [])
        path = repo_path(base, cache)
        if not truth:
            # No copy to check against: report as-is rather than guessing.
            resolved.append((path, reported, operator))
        elif reported in candidates:
            resolved.append((path, reported, operator))
        else:
            phantoms.append((path, reported, operator))

    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "survivors.tsv"), "w") as fh:
        fh.write("file\treported_line\ttrue_line\toperator\tsource\n")
        for path, line, operator in sorted(resolved):
            fh.write(f"{path}\t{line}\t{line}\t{operator}\t{source_line(path, line)}\n")

    # A MACHINE-READABLE twin of the markdown, written for the trend tool.
    # report.md is for a human triaging one run; nothing could read a series of
    # them without re-parsing prose, so the numbers are emitted once, here,
    # where they are already known and already phantom-filtered.
    shard_nums = [int(n) for n in re.findall(r"\d+", label)]
    json.dump(
        {
            "shard": shard_nums[0] if shard_nums else None,
            "shardCount": shard_nums[1] if len(shard_nums) > 1 else None,
            "killed": len(killed),
            # `survived` is the PHANTOM-FILTERED count -- the real holes. It is
            # deliberately NOT the number in report.md's table, which carries
            # Muter's raw count so it reconciles with Muter's own summary. Both
            # are emitted under distinct names because a trend built on the raw
            # count would read phantoms as regressions.
            "survived": len(resolved),
            "reportedSurvived": len(survived),
            "survivors": [
                {
                    "file": path,
                    "line": line,
                    "operator": operator,
                    "source": source_line(path, line),
                }
                for path, line, operator in sorted(resolved)
            ],
            "phantoms": [
                {"file": path, "line": line, "operator": operator}
                for path, line, operator in sorted(phantoms)
            ],
            "runtime": TOOK.search(text).group(1) if TOOK.search(text) else None,
        },
        open(os.path.join(out_dir, "summary.json"), "w"),
        indent=2,
        sort_keys=True,
    )

    out = [f"**{label}**", ""]
    if not rows:
        out += [
            "**Muter produced no mutant outcomes at all.** That is a tooling failure,",
            "not a measurement -- most likely the insertion patch no longer applies.",
            "Do not read a score from this run.",
        ]
    else:
        out += [
            "| killed | survived | score | runtime |",
            "|---:|---:|---:|---|",
            f"| {len(killed)} | {len(survived)} | "
            f"{SCORE.search(text).group(1) + '%' if SCORE.search(text) else 'n/a'} | "
            f"{TOOK.search(text).group(1) if TOOK.search(text) else 'n/a'} |",
            "",
        ]
        if not truth:
            out += [
                "> **Positions are Muter's own and are known to be wrong.** The mutated",
                "> copy was unavailable, so line numbers could not be corrected. Treat",
                "> every line below as approximate and confirm before acting.",
                "",
            ]
        if survived:
            out += [
                "### Survivors",
                "",
                "A survivor is a **question**, not a defect: the suite could not tell the",
                "difference when this expression changed. Before writing a test, confirm the",
                "mutant by hand -- delete or flip the expression and check the suite actually",
                "fails. Some mutants are unkillable by construction; close those with the",
                "reason and never chase a score. Everything listed here has already been",
                "checked against the mutated copy, so Muter's phantom mutants (reported but",
                "never inserted) have been filtered out into their own section below.",
                "",
            ]
            current = None
            for path, line, operator in sorted(resolved):
                if path != current:
                    out += ["", f"**`{path}`**", ""]
                    current = path
                src = source_line(path, line)
                out.append(f"- L{line} `{operator}`" + (f" — `{src}`" if src else ""))
        else:
            out.append("No survivors. Every mutant in this shard was killed.")

        if phantoms:
            out += [
                "",
                "### Phantom mutants — ignored, not holes",
                "",
                f"Muter reported {len(phantoms)} survivor(s) for which **no schema was actually",
                "inserted** into the mutated copy. The unmutated code ran, passed, and was",
                "recorded as a survivor. These are muter#308 artefacts, not gaps in the suite,",
                "and they are listed only so the count reconciles with Muter's own summary.",
                "",
            ]
            for path, line, operator in sorted(phantoms):
                src = source_line(path, line)
                out.append(f"- `{path}` L{line} `{operator}`" + (f" — `{src}`" if src else ""))

    out += [
        "",
        "---",
        "",
        "Coverage is deliberately partial: this is the logic tier only "
        "(`Tools/mutation/config.json`). APIServer is excluded on purpose — ~96% of the "
        "cost of the tree for its least-informative mutants. Method, costs and the "
        "reading guide: `docs/mutation-testing-pilot.md`.",
    ]

    report = "\n".join(out) + "\n"
    open(os.path.join(out_dir, "report.md"), "w").write(report)
    print(report)
    # No outcomes at all means the tool broke; a silent zero is the failure this
    # whole exercise exists to catch, so it must not pass quietly.
    return 1 if not rows else 0


if __name__ == "__main__":
    sys.exit(main())

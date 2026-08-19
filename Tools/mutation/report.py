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


def _skip_to_matching_brace(text: str, open_idx: int) -> int:
    """Index just past the `}` matching the `{` at `open_idx`, or -1.

    Brace counting has to ignore braces inside string literals, interpolations
    and comments, or a mutation containing `"{"` truncates the extraction. When
    anything looks wrong the answer is -1 and the caller records NOTHING: a
    guessed mutation is worse than an absent one, for the same reason a phantom
    is worse than a missing survivor -- somebody acts on it.
    """
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            # Raw strings (#"..."#) and multiline ("""...""") both start with a
            # quote; walk the literal with escape handling and bail out if it is
            # unterminated rather than guessing where it ends.
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                if j < 0:
                    return -1
                i = j + 3
                continue
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 2
                    continue
                i += 1
            if i >= n:
                return -1
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def _trailing_else_body(text: str, after_branch: int) -> str | None:
    """The `<original>` in the final `else` of a schema chain, or None.

    WHY THE ORIGINAL IS WORTH AS MUCH AS THE MUTATION. A mutation on its own can
    only be applied by POSITION, and Muter's positions are known-wrong -- this
    file's own report says so. Measured against run 32255707345: the reported
    line holds the whole mutated statement for 15 of 84 candidates and something
    else entirely for the other 69, because Muter records the ENCLOSING
    statement (often a whole computed-property body) while the line points at
    one operator inside it. Splicing that onto the reported line deletes a `case`
    label or comments out the rest of the line, and the compile error that
    follows reads as a failing suite -- which is to say, as "already covered".

    With the original in hand the replacement is exact and needs no position at
    all: find this text, put that text there. The chain is walked rather than
    regex-matched because `else if` branches nest arbitrarily and each carries a
    mutation of its own.
    """
    i, n = after_branch, len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if not text.startswith("else", i):
            return None
        i += 4
        while i < n and text[i].isspace():
            i += 1
        if text.startswith("if", i):
            brace = text.find("{", i)
            if brace < 0:
                return None
            end = _skip_to_matching_brace(text, brace)
            if end < 0:
                return None
            i = end
            continue
        if i < n and text[i] == "{":
            end = _skip_to_matching_brace(text, i)
            if end < 0:
                return None
            return text[i + 1 : end - 1].strip()
        return None
    return None


def harvest_schemata(mutated_root: str) -> tuple[dict[tuple[str, str], list[int]], dict]:
    """Read the mutated copy: true mutant positions AND the mutation itself.

    Muter rewrites each mutable statement into a switch whose branches carry the
    mutations and whose final `else` carries the original:

        if ProcessInfo.processInfo.environment["<id>"] != nil {
            <mutated>
        } else if ProcessInfo.processInfo.environment["<id2>"] != nil {
            <mutated 2>
        } else {
            <original>
        }

    Capturing `<mutated>` is what makes a survivor ACTIONABLE. Muter's own plain
    output gives a file, a line and an operator name -- and that is not enough to
    reproduce the mutant. `return (i > Int(Int32.max) || i < Int(Int32.min)) ? …`
    carries two comparisons, so "RelationalOperatorReplacement at line 57" names
    two possible mutations and says nothing about what either was replaced with.
    Anyone triaging it has to guess, and guessing wrong is not hypothetical: a
    triage pass that mutated whole `||` chains where Muter mutates one connector
    called three real gaps covered.

    A reported row cannot always be tied to ONE schema -- two mutants of the same
    operator can share a line -- so every candidate for a (stem, operator, line)
    is returned. Being handed two exact mutations beats being handed none.
    """
    positions: dict[tuple[str, str], set[int]] = {}
    mutations: dict[tuple[str, str, int], list[dict]] = {}
    if not mutated_root or not os.path.isdir(mutated_root):
        return {}, {}
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
            for m in SCHEMA_ID.finditer(text):
                stem, operator, line, col, off = m.groups()
                line = int(line)
                positions.setdefault((stem, operator), set()).add(line)
                brace = text.find("{", m.end())
                if brace < 0:
                    continue
                end = _skip_to_matching_brace(text, brace)
                if end < 0:
                    continue
                # An EMPTY body is not a failed extraction -- it is what
                # RemoveSideEffects looks like, since that operator deletes the
                # statement outright. Skipping it would leave the one operator
                # whose mutation is "nothing" permanently unverifiable, and the
                # events it deletes are exactly the kind nothing asserts on.
                body = text[brace + 1 : end - 1].strip()
                # The ORIGINAL, from the chain's trailing `else`. This is what
                # lets a verifier replace by CONTENT rather than by Muter's
                # known-wrong line number -- see `_trailing_else_body`. It may
                # legitimately be absent (a malformed or unterminated chain), in
                # which case the mutation is recorded without one and the
                # verifier refuses it rather than applying it blind.
                original = _trailing_else_body(text, end)
                record = {"column": int(col), "offset": int(off), "mutated": body}
                if original is not None:
                    record["original"] = original
                mutations.setdefault((stem, operator, line), []).append(record)
    return (
        {k: sorted(v) for k, v in positions.items()},
        {k: sorted(v, key=lambda d: d["offset"]) for k, v in mutations.items()},
    )


def harvest_true_positions(mutated_root: str) -> dict[tuple[str, str], list[int]]:
    """Positions only -- kept as the narrow entry point for the phantom filter."""
    return harvest_schemata(mutated_root)[0]


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

    truth, schemata = harvest_schemata(mutated_root)
    cache: dict[str, str] = {}

    # A reported survivor is only real if a schema was actually inserted for it.
    # Compare against the guards harvested from the mutated copy; anything with
    # no guard was never mutated, so its "survival" means nothing.
    resolved, phantoms = [], []
    mutation_of: dict[tuple[str, int, str], list[dict]] = {}
    for base, reported, operator, _ in survived:
        stem = base[:-6] if base.endswith(".swift") else base
        candidates = truth.get((stem, operator), [])
        path = repo_path(base, cache)
        if not truth:
            # No copy to check against: report as-is rather than guessing.
            resolved.append((path, reported, operator))
        elif reported in candidates:
            resolved.append((path, reported, operator))
            mutation_of[(path, reported, operator)] = schemata.get(
                (stem, operator, reported), []
            )
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
            # `survived` is the PHANTOM-FILTERED count -- the real holes, and
            # the same number report.md's table shows. `reportedSurvived` keeps
            # Muter's raw count so the two can be reconciled, but nothing should
            # SUM it: a trend built on the raw count reads phantoms as
            # regressions, and a headline built on it reads them as holes.
            "survived": len(resolved),
            "reportedSurvived": len(survived),
            "survivors": [
                {
                    "file": path,
                    "line": line,
                    "operator": operator,
                    "source": source_line(path, line),
                    # The mutation itself, lifted from the schemata in the
                    # mutated copy. Without it a survivor is not reproducible:
                    # an operator name plus a line number does not say WHICH
                    # sub-expression changed or what it became. A list because
                    # two mutants of one operator can share a line; empty when
                    # the copy was unavailable or the extraction was unsure,
                    # never a guess.
                    "mutations": mutation_of.get((path, line, operator), []),
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
        # The table carries the PHANTOM-FILTERED numbers, and the score is
        # recomputed from them rather than taken from Muter's summary.
        #
        # It used to print Muter's raw count "so it reconciles with Muter's own
        # summary", and the 2026-08-19 sweep showed what that costs: shard 0
        # read "50 survived, 37%" when 43 of those mutants were never inserted
        # and its real score was 81%. A human triaging that shard would have
        # concluded NotebookExtraction was barely tested. Reconciliation is
        # worth one line of prose; it is not worth the headline number.
        denominator = len(killed) + len(resolved)
        net_score = f"{round(100 * len(killed) / denominator)}%" if denominator else "n/a"
        muter_score = SCORE.search(text).group(1) + "%" if SCORE.search(text) else "n/a"
        out += [
            "| killed | survived | score | runtime |",
            "|---:|---:|---:|---|",
            f"| {len(killed)} | {len(resolved)} | {net_score} | "
            f"{TOOK.search(text).group(1) if TOOK.search(text) else 'n/a'} |",
            "",
        ]
        if phantoms:
            out += [
                f"> Muter's own summary claims {len(survived)} survivors and {muter_score}. "
                f"{len(phantoms)} of them were never inserted into the mutated copy "
                "(listed below), so the table above is the measurement and that one "
                "is not.",
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
                # The mutation, so the reader can reproduce it without guessing
                # which sub-expression Muter touched.
                for mut in mutation_of.get((path, line, operator), []):
                    one = " ".join(mut["mutated"].split())
                    if len(one) > 160:
                        one = one[:157] + "..."
                    out.append(f"    - becomes: `{one}`")
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

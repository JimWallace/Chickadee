# Triaging mutation survivors

This is the working protocol for turning a mutation sweep's survivor list into
tests. It is written to be handed to someone — or something — starting cold.

**Read this first: a survivor is not a bug.** It is one question, always the
same one: *the suite could not tell the difference when this expression changed
— should it have?* Three answers are legitimate, and the third is not failure:

| answer | what you do |
|---|---|
| yes, that behaviour should be pinned | write the test |
| no — nothing reaching this code can tell the difference | close it, **record why** |
| the mutant is already dead / never existed | close it, no test |

Anyone treating the list as a defect backlog will produce tests that pass while
proving nothing, which is the exact failure mutation testing exists to detect.
**There is no score to chase.** Some survivors are unkillable by construction,
and a run that "fixed" them would be worse than one that left them alone.

---

## The loop

Per survivor, twice through the verifier — before and after. Both runs matter,
and skipping the first is how you write a test for a hole that is not there.

```
Tools/mutation/verify-survivor.py --run-record MutationReports/<date>-run<id>.json \
    --file Sources/Core/JSONValue.swift --line 57 --operator ChangeLogicalConnector
```

**Before writing anything — expect `SURVIVED`.**
`KILLED` means the finding is stale (the code moved, or somebody already covered
it); close it and move on. `UNVERIFIABLE` means the mutation could not be
applied faithfully — no mutation was recorded, the recorded original no longer
appears in the file, or the mutated source did not build. Confirm by hand or
skip; never approximate one.

**A `KILLED` always names the suite that caught it.** If it says only
`suite failed`, read that as a bug report against the verifier rather than a
verdict — it is what a mis-applied mutation used to look like, and the reason
the applier now refuses rather than guesses (below).

**After writing the test — expect `KILLED`, naming your new suite.**
If your test passes but the mutant still survives, the test is not exercising
the behaviour it claims to. That is the whole point of the second run.

The verifier applies the mutation Muter actually inserted, taken from the run
record, and runs the sweep's own test command from `Tools/mutation/config.json`
so a verdict here means what a verdict there means.

**It applies the mutation by CONTENT, not by position, and this is load-bearing.**
Muter reports a file, a line and a column, and those positions are known-wrong —
`report.py` says so in the issue body it writes. Muter records the *enclosing
statement* while the line points at one operator inside it, so replacing the
reported line is only faithful when that line happens to hold the whole
statement: measured across run 32255707345, 15 of 84 candidates. For the other
69 the edit deletes a `case` label, pastes a whole expression beside the half
already above it, or splices in text that opens with `//` and comments out the
rest of the line. None of that fails honestly — it fails to COMPILE, the suite
goes red, and red used to read as `KILLED`, which this protocol spells "already
covered, do not write a test". A real gap closed itself.

So each mutation is recorded together with its `original` (the trailing `else`
of Muter's schema chain) and the edit is an exact textual swap. Records written
before that existed carry no `original`; the verifier refuses them rather than
falling back to position. **If a whole cluster comes back `UNVERIFIABLE` citing
a missing `original`, the answer is a fresh sweep, never a hand-edit.**

## Work by file, not by survivor

Survivors cluster. In the 2026-08-19 sweep, 36 of 95 were in the four
`JSONValue*Literal` renderers and 16 more in `AchievementEvaluation`. One
table-driven test usually kills several, and a per-survivor task list produces
redundant work plus one chance to guess wrong per item.

Take a file, read its survivors together, and ask what single test would pin the
behaviour they all poke at.

## Traps, all of them measured

**Mutate exactly what the tool mutated.** Muter's `ChangeLogicalConnector`
changes ONE connector; flipping a whole `a || b || c` chain to `&&` is a
stronger change that fails tests the real mutant survives. A triage pass that
did this called three genuine gaps "already covered". The verifier avoids the
trap entirely by replaying the recorded mutation — this is why you use it rather
than editing by hand.

**One line can carry several mutants.** `return (i > Int(Int32.max) || i <
Int(Int32.min)) ? …` has two comparisons, so `RelationalOperatorReplacement` at
that line names two possible mutations. The record lists every candidate and the
verifier tries each, reporting them separately. Do not assume the first is the
one that survived.

**Phantoms are already filtered — do not re-add them.** Muter reports mutants it
never inserted, and they always read as survived: 131 of 226 in the 2026-08-19
run, 43 of 50 in one shard. `Tools/mutation/report.py` quarantines them against
the guards actually present in the mutated copy. Read survivors from the run
record or the issue's Survivors section, never from Muter's raw output.

**A `Sources/Core` survivor is weaker evidence than a `Sources/RunnerCore` one.**
The sweep skips `APITests` because it dominates the runtime, and ~5% of Core is
reachable only from there. If a Core survivor sits in such a file, confirm it
against the full suite before writing anything — otherwise you are looking at
the same artefact a missing interpreter produces, where a test that never ran
makes its mutants read as gaps.

**Equivalent mutants are common in parsers and defensive code.**
`containsSubstring`'s empty-needle guard has no caller that passes an empty
needle. `JSONLite`'s `parseNumber` is a subtler one: mutating `if current == "-"`
to `!=` changes nothing, because the `while` loop that follows accepts `-` too
and `start` is captured before either — so the sign is consumed either by the
`if` or by the loop, and the slice handed to `parseDoubleLiteral` is identical
for every input `parseValue` can route there. Close these with the reason
written down; the reason is the deliverable.

**But make the argument about the mutation Muter actually generates, not the one
you can imagine.** This section used to claim `skipWhitespace`'s `\n` arm was
unkillable, because the footer is by definition the last non-empty *line*. The
reachability half is right and the conclusion was wrong: `ChangeLogicalConnector`
mutates ONE connector in `" " || "\t" || "\n" || "\r"`, so no candidate isolates
`\n`. Each disables a *pair* — and the pairs reach tabs (interior ones survive
`trimHorizontal`) and a lone `\r`, both of which a script can emit. Measured
against run 32265903112, two of those three candidates survived the suite and
both are now killed by `JSONFooterGrammarTests`. An equivalence argument has to
name the recorded mutation and show THAT one cannot be observed.

## What a finished survivor looks like

Either a test that has been seen to fail under its mutation, or a sentence
saying why no test should exist. Both are complete. A survivor left open with
neither is the only bad outcome.

When a test lands, say in its comment what the mutation was and why the gap
mattered — the tests added from the first pilot do this, and it is what stops a
later reader deleting them as redundant.

## Where things are

| | |
|---|---|
| run records (the series) | `mutation-reports` branch, `MutationReports/*.json` |
| the sweep | `.github/workflows/mutation-weekly.yml`, Tuesdays 06:00 UTC |
| scope and its reasoning | `Tools/mutation/config.json` |
| the trend | `Tools/mutation/trend.py` |
| why the tooling distrusts its own tool | `docs/mutation-testing-pilot.md` |
| tracking issue | #1447 |

Pull the current series with:

```
git fetch origin mutation-reports
git checkout FETCH_HEAD -- MutationReports
python3 Tools/mutation/trend.py
```

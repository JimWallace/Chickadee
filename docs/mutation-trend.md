# Reading the mutation trend

**What this answers: is the test suite getting better at telling the difference
when the source changes?** One mutation score cannot answer that. A series can.

Run it:

```
python3 Tools/mutation/trend.py
```

Prerequisites and cost are not this document's subject — see
[mutation-testing-pilot.md](mutation-testing-pilot.md) for what a sweep costs
and [handoff-mutation-testing.md](handoff-mutation-testing.md) for why the tool
is a patched fork.

---

## Where the numbers come from

The weekly sweep shards ten ways. Each shard writes a `summary.json`; the merge
job folds all ten into one `MutationReports/<date>.json` and commits it. The
trend tool reads that directory and nothing else.

| | |
|---|---|
| `killed` | mutants the suite detected |
| `survived` | mutants it did not, **after phantom filtering** |
| score | `killed / (killed + survived)`, recomputed from counts |
| shards | how much of the logic tier this run actually covered |

The score is recomputed rather than averaged from the shards' own percentages:
shards differ in mutant count, so the mean of ten percentages is not the
percentage of the whole.

`survived` here is smaller than the number in a shard's `report.md`, by design.
Muter reports mutants it never inserted and they always read as survivors;
`Tools/mutation/report.py` quarantines those against the mutated copy. The
markdown keeps Muter's raw count so it reconciles with Muter's own summary; the
trend uses the filtered count, because a trend built on phantoms reads tooling
noise as regression.

## How to read the score

**It is always lower than line coverage, and that is the point.** Coverage asks
whether a line ran. Mutation asks whether anything would have *noticed* if that
line were wrong. A line can be executed by ten tests and still have no assertion
that constrains it — covered, and unverified. That gap is the whole reason this
exists: the recurring defect in this codebase is verification that passes while
proving nothing.

**A surviving mutant is an assertion gap, not a failing test.** Nothing is
broken. The suite could not distinguish the mutated source from the original.
That is a question addressed to a human, and the answer is sometimes "correctly,
no test".

**Do not chase the percentage.** A meaningful fraction of survivors are
*equivalent mutants* — unkillable by construction, because no input that can
reach that code tells the difference. The pilot found several in `JSONLite`:
`skipWhitespace` treating `\n` as skippable, when the footer is by definition
the last non-empty *line* and can never contain one. Writing a test for those
means writing tests for inputs that cannot occur. This is why there is no
threshold anywhere and why the sweep is a report, never a gate.

So read the trend for **direction**, not altitude. A score that drifts down
while the shard count holds steady means new code is arriving less
well-asserted than the code already there.

## Two things that would otherwise lie to you

Both make the numbers move for reasons that have nothing to do with the suite,
and both are marked in the table rather than left to be noticed.

**`PARTIAL` — the run did not cover everything.** A shard that dies uploads
nothing, so its mutants are absent from both counts. Fewer survivors, which
reads exactly like progress. A row showing `7/10` is not comparable with one
showing `10/10`, and partial runs are excluded from the persistent backlog.

**`CONFIG CHANGED` — the measurement changed.** The score depends on what was
mutated (`include`), how mutants were graded (`testArgs`), and which Muter built
them. Change any of those and the next number is a different measurement in the
same units. **A score is only comparable between runs with the same
configuration.** Runs carry a fingerprint; when it changes the trend marks the
row and starts the persistent-survivor set over, because a survivor cannot be
"still surviving" across a run that never mutated its file.

## The persistent backlog

Survivors present in *every* comparable, complete run. This is the standing set
— the holes that have survived every attempt so far, and where the equivalent
mutants accumulate.

Survivors are identified by `(file, operator, source text)`, deliberately **not
by line number**. Line numbers move whenever anything above them is edited, so a
line-keyed backlog empties itself on the first unrelated commit and reports the
holes as fixed. The line shown is from the most recent run, since triage happens
against today's source.

## Triaging one survivor

1. **Confirm it by hand.** Make the mutation yourself and check the suite
   actually passes. The tool's failure modes are silent and its output is
   audited, not trusted.
2. **Decide whether a test should exist.** If no reachable input distinguishes
   the mutant, it is equivalent — close it with the reason.
3. **If a test should exist, write it.** One fixture often kills several
   neighbours at once; the pilot noted a single generously-spaced JSON footer
   would have killed four `skipWhitespace` survivors together.

Closing a survivor with a reason is a legitimate outcome, not a backlog item.

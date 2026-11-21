# Reading the mutation trend

**What this answers: is the test suite getting better at telling the difference
when the source changes?** One mutation score cannot answer that. A series can.

Run it:

```
python3 Tools/mutation/trend.py
```

Prerequisites and cost are not this document's subject — see
[mutation-testing-pilot.md](mutation-testing-pilot.md) for what a sweep costs
and [handoff-mutation-testing.md](archive/handoff-mutation-testing.md) for why the tool
is a patched fork.

---

## Where the numbers come from

The weekly sweep shards the logic tier (`shardCount` in
`Tools/mutation/config.json` — twelve as of the Worker widening). Each shard
writes a `summary.json`; the merge job folds them into one
`MutationReports/<date>-run<id>.json` and commits it to the `mutation-reports`
branch. The trend tool reads that directory and nothing else.

| | |
|---|---|
| `killed` | mutants the suite detected |
| `survived` | mutants it did not, **after phantoms and recorded equivalents are removed** |
| score | `killed / (killed + survived)`, recomputed from counts |
| shards | how much of the logic tier this run actually covered |

The score is recomputed rather than averaged from the shards' own percentages:
shards differ in mutant count, so the mean of ten percentages is not the
percentage of the whole.

`survived` here is smaller than the number in a shard's `report.md`, by design.
`Tools/mutation/report.py` takes these rows out of it before it writes the
shard's `summary.json` (inert no-op mutations go too; see
[mutation-triage.md](mutation-triage.md)):

- **Phantoms.** Muter reports mutants it never inserted, and they always read as
  survivors. `report.py` quarantines those against the mutated copy. A trend
  built on phantoms reads tooling noise as regression.
- **Recorded equivalents.** A survivor whose mutation text matches an entry in
  `Tools/mutation/equivalent-mutants.json` has already been answered with an
  argument instead of a test ([mutation-triage.md](mutation-triage.md) says what
  an entry must contain). It is counted in neither `killed` nor `survived`.

The markdown keeps Muter's raw count so it reconciles with Muter's own summary.

**What the weekly sweep covers.** The logic tier is `RunnerCore`, `Core` and
`Worker` (`include` in `Tools/mutation/config.json`). `APIServer` is not in the
sweep. The nightly steward's "Deeper sweeps" step (`Tools/maintenance/nightly.md`)
runs the tool on tiers the weekly sweep skips, such as `APIServer`. Only the
weekly merge job writes to `mutation-reports`, so those runs are not in the
trend. A score here says nothing about `APIServer`.

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

**Some mutants are unkillable, and the score does not count them.** An
*equivalent mutant* is unkillable by construction, because no input that can
reach that code tells the difference. The pilot found several in `JSONLite`:
`skipWhitespace` treating `\n` as skippable, when the footer is by definition
the last non-empty *line* and can never contain one. A test for those would test
inputs that cannot occur. Once an equivalent is recorded in the ledger, it leaves
both counts, so the score can reach 100%.

**100% means the queue is empty, not that every mutant was killed.** It says
that every mutant in scope was either killed by a test or answered with a
recorded argument. That is the state to hold, and since the 2026-11-17 sweep
the logic tier has been in it. From here, read the **survivor count**, not the
percentage:

- **Zero survivors** is the normal state. A run that stays at zero tells you
  nothing new.
- **Any survivor** is new work: either new code arrived without an assertion
  that constrains it, or an edit invalidated a ledger entry (entries match the
  mutation text, so they stop matching when the code changes). Each one gets
  triaged, as below.
- **A falling score with a steady shard count** still means what it always did:
  new code is arriving less well-asserted than the code already there.

There is still no threshold, and the sweep is still a report, never a gate.
A gate would push the next person to ledger a survivor to get green, and a
ledger entry made for that reason is a lie (see below).

## Three things that would otherwise lie to you

Each makes the numbers look better or worse for reasons that have nothing to do
with the suite. The first two are marked in the table rather than left to be
noticed. The third is not visible in the table at all.

**`PARTIAL` — the run did not cover everything.** A shard that dies uploads
nothing, so its mutants are absent from both counts. Fewer survivors, which
reads exactly like progress. A row showing `7/8` is not comparable with one
showing `8/8` — the 2026-08-25 scheduled run was exactly this, one shard lost
to a baseline flake — and partial runs are excluded from the persistent
backlog.

**`CONFIG CHANGED` — the measurement changed.** The score depends on what was
mutated (`include`), how mutants were graded (`testArgs`), and which Muter built
them. Change any of those and the next number is a different measurement in the
same units. **A score is only comparable between runs with the same
configuration.** Runs carry a fingerprint; when it changes the trend marks the
row and starts the persistent-survivor set over, because a survivor cannot be
"still surviving" across a run that never mutated its file.

**A wrong ledger entry — the score is only as honest as the ledger.** A
survivor that matches `equivalent-mutants.json` disappears from both counts. If
the entry's argument is wrong, a real assertion gap is hidden and the score
still reads 100%. Nothing in the table shows this. The ledger is small, so
re-read its entries now and then against the current source, and treat an
entry added only to clear a survivor as a gap, not an answer.

## The persistent backlog

Survivors present in *every* comparable, complete run: the holes that have
survived every attempt so far. Equivalent mutants used to collect here. They now
go into the ledger, so the backlog should be empty. A survivor that stays in it
for two comparable runs has been left untriaged.

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
   the mutant, it is equivalent — record it in
   `Tools/mutation/equivalent-mutants.json` with the reason, so the next sweep
   does not report it again.
3. **If a test should exist, write it.** One fixture often kills several
   neighbours at once; the pilot noted a single generously-spaced JSON footer
   would have killed four `skipWhitespace` survivors together.

Closing a survivor with a reason is a legitimate outcome, not a backlog item.

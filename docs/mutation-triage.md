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

**A full-suite kill on a Core survivor is not automatically a close.** The
question the confirmation answers is "does any test detect this", and a second
question follows it: is the test that detects it in the right layer.
`PatternCase`'s length-alignment rule and `NotebookFunctionInfo`'s decoder
realignment are Core model invariants whose only assertions lived in an
APIServer renderer suite. The full suite kills their mutants, so they are not
undetected — but every non-APIServer consumer of those models was relying on a
test that does not exercise it, and the sweep could not see the rule at all.
Both got a `Tests/CoreTests` assertion rather than a ledger entry. Reserve the
ledger for mutants nothing *can* observe; "observed from somewhere else"
belongs in a test where the invariant lives.

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

**When the answer is "no test", write it in `Tools/mutation/equivalent-mutants.json`.**
A reason recorded only in a commit message is invisible to the next sweep, so the
survivor comes back every week looking exactly like an untriaged gap — and
whoever picks it up either re-derives the argument or writes a test asserting
something that cannot vary. An entry there moves it out of the open list into
report.md's "Already answered" section.

Three things about that file, because it is one careless edit away from being a
suppression list:

- **It is keyed on the mutation text, not a line number.** Lines move, and a
  stale line would silently excuse whatever mutant drifted into it. Matching the
  normalised mutated statement also means an entry self-invalidates when the code
  is edited: the survivor reappears and the argument gets made again against the
  code as it now is. That is the desired behaviour, not a nuisance.
- **`reason` must be an argument.** Say which inputs can reach the site and why
  none of them distinguishes the two versions. `report.py` refuses an entry
  shorter than a sentence, but it cannot tell a bad argument from a good one.
- **Never park a hard-to-kill mutant there.** That is a gap, and a gap in this
  file is indistinguishable from a lie.

## The number to watch is the queue, not the score

There is no coverage target here, and the mutation percentage is not one either:
some mutants are unkillable by construction, so a suite that drove it to 100%
would be asserting things that cannot vary. Muter also reports outcomes that are
not mutants at all — 134 phantoms and 9 inert no-ops in run 32265903112, against
383 real ones.

What can honestly reach zero is the count of survivors nobody has answered yet.
Killed mutants leave the list on their own; phantoms, inert mutations and
recorded equivalents are filtered into their own sections. What remains is the
queue, and emptying it is the goal.

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

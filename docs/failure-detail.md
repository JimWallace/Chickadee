# Failure detail: how much of a failing test a student sees

The tier system decides **whether** a student sees a test. The failure-detail
setting decides **how much of its failure** they see. It exists so a test can
sit on the public tier without its failure message carrying the expected
answer.

## The three levels

| Level | The student sees |
|---|---|
| `full` (default) | Everything the script printed: the message, the expected value, their value, any diff or traceback. |
| `actualOnly` | Their own side only: the input echo, their output, the error their code raised, where it raised, how long it took. The expected value, a diff, a tolerance or a time budget are withheld. |
| `verdictOnly` | The verdict alone: "did not pass", "error" or "timed out". No message text. |

The hint shows at every level. It is written for the student, and a hint that
says "mind the 18.5 boundary" is the instructor's choice to make.

Staff always see the full text. A pass is never masked. A test skipped because
a prerequisite failed shows its skip message as before.

## Where it is set

Per suite entry, in every authoring door:

- The suite editor's script modal has a **Failure detail shown to students**
  select beside the hint and the time limit.
- The family editor has a family-wide default; a per-case value is available
  through the MCP tools (`create_pattern_family` and `update_pattern_family`,
  `defaultFailureDetail` and `cases[].failureDetail`).
- The notebook-check editor has the same select among its common fields;
  `author_notebook_check` takes `failureDetail`.
- `author_script` and `update_suite` take `failureDetail` for hand-written
  scripts; `get_suite` reports it per item.

The stored value is `TestSuiteEntry.failureDetail`. A family or check writes
its resolved value onto every entry it generates, so the results page reads
entries alone. `full` is stored as absence, so a manifest that predates the
field, or an entry reset to the default, reads exactly as before.

## Where it is applied

At results-display time, in `SubmissionResultPresenter.renderOutcomeRow`,
through `maskFailureOutput`. The generated script prints everything it knows.
This is deliberate: a setting can be relaxed after the fact and every past
result re-reads under the new level, and the browser grader, which runs the
suite in the student's own tab, needs no change.

That last point is also the setting's limit. A browser-graded assignment
sends the full outcome text to the student's browser, and the page masks it.
The masking is a display policy, not a secret. A test whose expected value
must never reach the student belongs on the worker path and a hidden tier, as
`docs/datasets.md` says of every browser-graded secret.

## What `actualOnly` keeps, and why it fails closed

A generated failure message is a headline line followed by labelled fields:

```
wrong value
  input:    classify(3)
  expected: 'overweight'
  got:      'normal'
```

`actualOnly` keeps the headline when it is one of the phrases the generators
emit (`GeneratedMessage.failureHeadlines`) and keeps a field when its label
is in `GeneratedMessage.studentSideLabels`: `input`, `got`, `error`,
`source`, `raised`, `took`, `elapsed`, `position`, `searched`, `content`,
`row`. An unlabelled line follows the field before it, so a multi-line `got`
value survives whole; text before the first label, such as a traceback, is
dropped.

Both lists are allowlists. A label nobody has classified is withheld, so a
new field cannot leak the answer until someone decides it is the student's.
The consequence for a hand-written script is that `actualOnly` degrades to
the verdict: nothing about its output says which half is the answer, and a
first line of `expected 42, got 7` is exactly the case the level exists to
prevent. Use `verdictOnly` on a hand-written script when its output must be
withheld, or print the student's side under the standard labels.

Some runtimes (R, Lua, Octave, C++, Java) carry the whole message in the
footer's `shortResult` rather than on stderr. The masker reads `longResult`
first and falls back to `shortResult`, so every language masks the same way.

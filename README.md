# `mutation-reports`

**This branch is written by a robot and contains no source code.** It holds one
JSON record per mutation-testing sweep, and nothing else. Do not merge it into
`main`; it shares no history with the source tree.

Each record is produced by `.github/workflows/mutation-weekly.yml` (on `main`)
and named `<date>-run<run id>.json`. The run id is part of the name because a
manual dispatch beside the Tuesday schedule puts two sweeps on one day, and
keying on the date alone made the second silently overwrite the first.

Read the series with the tooling on `main`:

```
git fetch origin mutation-reports
git checkout FETCH_HEAD -- MutationReports
python3 Tools/mutation/trend.py
```

## Reading a record

`killed` and `survived` are **phantom-filtered** — Muter reports mutants it
never inserted, and those always read as survived, so they are excluded from
both numbers and listed separately. `reportedSurvived` in a shard's own summary
keeps Muter's raw count for reconciliation; never sum that one.

A score is only comparable against another run with the same `config.configHash`.
`trend.py` marks a row `CONFIG CHANGED` rather than drawing a line through two
measurements that are not the same measurement.

## Why the branch exists

The records used to be pushed to `main`, which cannot work: that requires a pull
request and passing status checks, and a bot committing a generated artifact
satisfies neither. The failure was swallowed by `continue-on-error`, so a series
that could never accumulate looked exactly like a series with nothing in it yet.

Background: `docs/mutation-testing-pilot.md` and issue #1447.

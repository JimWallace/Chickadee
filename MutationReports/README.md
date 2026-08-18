# Mutation run records

One JSON file per sweep, written by `.github/workflows/mutation-weekly.yml` via
`Tools/mutation/merge-run.py` and committed automatically. Read the series with:

```
python3 Tools/mutation/trend.py
```

These are **committed rather than uploaded** on purpose. The sweep's other
outputs — ten per-shard artifacts and one issue body — both expire or are prose,
and a trend needs a series that outlives the artifact retention window.

Do not hand-edit a record. Each one carries the fingerprint of the configuration
that produced it (`muterRef`, `patchHash`, `configHash`, `swift`), and the trend
tool uses that to refuse comparisons between runs that are not the same
measurement. Editing a record silently makes two incomparable runs look
comparable, which is the one failure this whole series exists to avoid.

`survived` is the phantom-filtered count — real holes. `report.md` in the run
artifacts carries Muter's raw count instead, so the two differ by design. See
`Tools/mutation/report.py` for why phantoms exist.

# Performance log

One section per week, newest first, written by the weekly performance task
(`Tools/perf-bench/weekly-task.md`) and merged by the maintainer. The plan
behind it is [performance-program.md](performance-program.md); the benchmark
baseline is in [database-performance.md](database-performance.md).

A section has this form:

```text
## Week of YYYY-MM-DD (vX.Y.Z)

### Flagged
- one line per number that moved more than 25%, or a page count that changed;
  "None" when nothing moved

### Production
| Number | Value | Last week |
|---|---|---|
| ... | ... | ... |

### Benchmark (Tools/perf-bench/weekly.sh)
| Page or scenario | Statements | Rows | Time | Baseline |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

### Top statements by total time
| Calls | Mean ms | Statement (first 80 characters) |
|---|---|---|
| ... | ... | ... |
```

A number that could not be read says `not read:` and the reason.

<!-- New sections go below this line. -->

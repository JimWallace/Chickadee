### Changed

- **The mutation trend docs describe the equivalent-mutant ledger.** `docs/mutation-trend.md` now says that the trend's survivor count leaves out recorded equivalents, so a 100% score means the survivor queue is empty, not that every mutant was killed. It adds what the weekly sweep covers (`RunnerCore`, `Core` and `Worker`, not `APIServer`) and names a wrong ledger entry as a way the score can mislead. `trend.py`'s backlog note and `docs/mutation-triage.md` now say the same.

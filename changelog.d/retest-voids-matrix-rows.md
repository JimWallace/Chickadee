### Fixed

- **A round-robin retest after a classmate resubmitted no longer inflates the standings.** The re-claim chose the classmate's newer entry under a new identity, so the old completed row stayed beside the new one and `played`, `wins` and the average counted both. The matrix claim now voids the submission's completed rows before it opens the current set (#1744).

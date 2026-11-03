### Fixed

- **Deleting an assignment removes everything the course purge removes for it (#2809).** The assignment delete now removes the submission files after the transaction commits, and deletes the class coverage, class-goal, composite and dataset-deal rows, several of which name the contributing student. It also removes validation variants when the setup has no submissions. Both deletes share one helper, `SetupRowDeletion`, so they cannot drift apart again.

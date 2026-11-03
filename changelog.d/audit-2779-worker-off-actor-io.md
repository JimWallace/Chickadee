### Fixed

- **Runner job slots no longer stall each other on workspace I/O (#2779).** The workspace setup, the submission staging and normalization, the disk-usage walk and the recursive teardown now run off the runner's daemon actor. With `--max-jobs` above 1, a large teardown in one slot no longer holds up the heartbeats, polls and reports of the other slots. The order of the steps and the cleanup guarantees do not change.

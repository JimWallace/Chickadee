### Changed

- **The UI review agents name a model family.** `ui-review` runs on `sonnet` and `ui-audit` on `opus`, in CI and in local sessions. Each is a family alias, so it always selects the newest model of that tier and needs no update when a new model ships.

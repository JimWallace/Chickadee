### Changed

- **The Students page lists course staff and students separately.** Each row shows the person's own avatar, the same bird as on their account page, with the username under the name, a role select, and an eye link to their submissions. Remove from course moved into a ⋯ menu. Enrol from CSV and Add staff member share one `+ Add` menu. The Filter box appears only with 8 or more students. Sorting stays on the column headers.
- **The Slip days page shows the numbers as facts.** The policy sits in a facts card with an `Edit settings` button, and the ledger has an avatar, pips for each day, `−` and `+` buttons, and a ⋯ menu with one refund per refundable spend. The most-used students come first.

### Removed

- **The "Check against LEARN" button on the Students page.** The roster-readiness sweep already stores each student's status, and the page now shows a "Not on LEARN classlist" flag beside the name. The `/instructor/students/learn-check` route is unchanged.

### Fixed

- **Add panels have inner padding.** The add-material form on the Overview lost its padding when it was built on a bare card.

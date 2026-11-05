### Fixed

- **The weekly dependency sweep reports every stuck Dependabot PR.** It reported only a PR without auto-merge. A PR with auto-merge on that conflicted with `main`, fell behind it, or had a required check that never reported stayed open with no issue. The sweep now reports any Dependabot PR open after three days, and the issue says why it is stuck.

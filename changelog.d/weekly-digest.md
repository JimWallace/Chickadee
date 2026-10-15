### Added

- **A weekly digest of the scheduled reports.** Every Monday afternoon, `weekly-digest.yml` has a small model (the haiku family) read the week's ZAP scan, the open CodeQL alerts, the kernel-currency result (with the upstream release notes of any kernel that moved), the flake tally and the open Dependabot PRs, and file one issue: what is new, and at most five items that need a person. The reports themselves do not change. It never dispatches a re-vendor or merges anything.

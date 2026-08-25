### Changed

- **No workflow pins a Node 20 action any more.** GitHub's runners deprecated
  Node 20 (2025-09-19) and force such actions onto Node 24 with a warning in
  every affected job — the mutation sweep, probe, and per-PR workflows, the
  kernel re-vendor, the browser-grading smoke, and visual regression all
  carried one or more. The fifteen stale pins move to the majors that declare
  Node 24, most already in use elsewhere in this repository: `checkout` v4→v6,
  `cache` v4→v5, `upload-artifact` v4→v7, `download-artifact` v4→v8,
  `setup-node` v4→v6, `setup-python` v5→v6, and `github-script` v7→v8. Every
  target's `action.yml` was checked for `using: node24`, and every remaining
  pin in the tree (docker, CodeQL, codecov, trivy, zap, the composite
  actions) verified as Node 24, composite, or docker — so the deprecation
  warning is gone repository-wide, not just moved.

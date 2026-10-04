### Changed

- **CLAUDE.md's Current State keeps the Leaf rules and drops the history.** The 0.4 arc moved to the top of `CHANGELOG-0.4.md`. The Leaf findings (the comment table, the line-comment leak, the `isEmpty` sites, the sub-context form, the scanner corollary) moved to a new section 0 of `docs/leaf-decomposition-review.md`, and CLAUDE.md keeps each rule as one bullet. `scripts/check-leaf-semantics.sh` now points to that section instead of CLAUDE.md (#1989).

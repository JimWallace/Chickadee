### Changed

- **Tests for the notebook working-copy store.** New suites cover the refresh that keeps a copy differing only in its outputs and rewrites a changed one, the template view that seeds from the stored starter and not from a submission, a submission that is not a notebook, the personalization fallbacks (a manifest that does not decode, a failed substitution, expressions with no seed, an expression that raises), the refusals when a past submission is opened, and the logged failures of a support-file link and a shared-dataset link. No product code changed.

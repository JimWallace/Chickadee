### Changed

- **Auto-release holds on the `minor-release` label, not only on contract paths** (#3061). A pull request labelled `minor-release` now stops auto-release exactly as a change to a contract path does: no patch, a pre-release for the dev server instead, and the `minor-needed` issue naming it. Before, a labelled compatibility removal that touched no contract path, such as removing a runner flag, would have shipped in a patch, which deploys on its own in `gated-minors`. If GitHub cannot be asked for a commit's pull request, the job fails rather than release.

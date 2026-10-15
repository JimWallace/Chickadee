### Added

- **An explanation of each visual-regression failure.** When the visual check fails on a PR, `visual-diff-explainer.yml` has a model (the sonnet family) compare each changed page's baseline, capture and diff image with the PR's UI diff, and comment once per PR: what changed, and whether the diff explains it. It is a report; the visual check stays the gate.

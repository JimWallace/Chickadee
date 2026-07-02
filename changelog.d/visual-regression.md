### Added

- **Visual regression harness (#1136).** `Tools/visual-regression/` boots the
  real server, seeds a course/assignment/student over the HTTP API, and
  screenshots six key pages in both light and dark mode, diffing against
  committed baselines (anti-aliasing-aware, 0.1% pixel budget, dynamic
  regions masked). Runs in CI on UI-touching PRs (`visual-regression.yml`,
  not a required check); intentional look changes regenerate baselines with
  `run-visual.sh --update` in the same PR, making the visual diff part of
  review. Closes the "guards can't prove it looks right" gap — the #1133
  dark-mode banner bugs would have failed this job on their introducing PR.

### Security

- **GitHub Actions are pinned to commit SHAs.** Every `uses:` in the workflows
  and the composite actions names a full commit SHA, with the version in a
  comment. A moved tag can no longer run new code in the pipeline. Dependabot
  now also updates the composite actions under `.github/actions/` (#3064).

### Security

- **The release job runs in a protected environment.** `auto-release.yml`
  uses the `release` environment, which admits only `main` and `v*` tags.
  A secret stored there cannot be read by a workflow on any other branch
  (#3071).

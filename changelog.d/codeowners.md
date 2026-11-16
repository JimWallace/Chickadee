### Security

- **The pipeline files have an owner.** `.github/CODEOWNERS` names an owner
  for the workflows, the deploy scripts, the Dockerfile and the release
  script, so a pull request that changes them asks that owner for review.
  The `v*` release tags are now protected by a ruleset: they cannot be
  moved or deleted, and only an admin can create one (#3072).

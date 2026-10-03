### Removed

- **`scripts/check-version.sh`.** No workflow, script or test ran it, and it called `rg`, which the CI images may not carry. `docs/release-process.md` said it enforced `VERSION == ChickadeeVersion.current`; it now says what does: `scripts/assemble-release.sh` writes both from one variable (#1984).

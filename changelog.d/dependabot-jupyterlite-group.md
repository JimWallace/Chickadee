### Fixed

- **Dependabot bumps `jupyterlite` and `jupyterlite-core` together.** The two pins in `Tools/jupyterlite/requirements.txt` must match, because the metapackage requires the core of its own version. Dependabot bumped them in separate PRs, and pip could not resolve either one, so the re-vendor workflow failed. They are now one Dependabot group.

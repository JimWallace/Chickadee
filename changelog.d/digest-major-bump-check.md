### Changed

- **The weekly digest asks for a check of a major kernel bump, not a hold.** The re-vendor pull request auto-merges on green CI, usually before the digest runs, so "hold" was an instruction nobody could follow (#2848). The digest now asks a person to read the release notes and check the kernel, and says the update may already be live.

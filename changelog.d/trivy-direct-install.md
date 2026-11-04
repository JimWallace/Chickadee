### Fixed

- **Image builds install Trivy from its GitHub release.** The vulnerability scan installed Trivy through a download host that stopped resolving on GitHub's runners once the cached binary was evicted. No image was published from v0.5.811 to v0.5.818, so production stayed on v0.5.810. The workflow now downloads the release tarball, checks a pinned SHA-256, and tells the scan action to skip its own installer.

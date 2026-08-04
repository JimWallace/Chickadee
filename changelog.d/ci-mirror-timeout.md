### Fixed

- **The CI image rebuild no longer times out.** `mirror-images.yml` builds the
  derived `swift-ci` image by apt-installing a heavy package set from
  `archive.ubuntu.com` behind a retry loop; with that mirror flaking the build
  step alone consumed 29.3 of its 30-minute budget and was killed, leaving the
  image unpublished. Since the job runs weekly, a silent timeout means a stale
  CI image for everyone. Budget raised to 60 minutes.

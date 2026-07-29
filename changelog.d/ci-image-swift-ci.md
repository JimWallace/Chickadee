### Added

- **Derived CI test image `swift-ci:6.3-noble`.** `mirror-images.yml` now
  builds and publishes a CI image layering the test jobs' system packages
  (`file`, `python3`, `zip`, `unzip`, `curl`) onto the mirrored Swift
  toolchain, immediately after each mirror refresh. Groundwork for dropping
  the 20–40 s per-job apt-get steps (adopted by the test workflows in a
  follow-up); toolchain identity is unchanged so `.build` cache keys keep
  matching.

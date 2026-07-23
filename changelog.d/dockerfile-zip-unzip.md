### Changed

- **Install `zip`/`unzip` explicitly in the runtime image.** The server and
  worker shell out to `/usr/bin/{zip,unzip}` for test-setup extract/publish,
  course-bundle import/export, and the personal-data export, but those
  binaries were only ever present transitively in the `ubuntu:24.04` base.
  They are now an explicit apt dependency so a future base-image change can't
  silently drop them and break those paths.

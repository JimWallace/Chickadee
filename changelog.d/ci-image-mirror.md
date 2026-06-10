### Changed

- **CI images mirrored to GHCR; superseded PR runs cancelled.** The
  swift/postgres job containers are now pulled from a GHCR mirror
  (refreshed weekly by `mirror-images.yml`) instead of Docker Hub, whose
  unauthenticated rate-limited pulls were the largest source of red CI on
  main (6 docker-pull timeouts in the three-week #890 audit window).
  `swift-tests.yml` also gained a `concurrency` group that cancels
  superseded runs on PR branches (pushes to main and merge-queue runs are
  unaffected).

### Changed

- **Browser probe jobs run in the `swift-ci` image and own a build cache.** They
  previously used the plain Swift mirror and `apt-get`-installed Node and npm at
  job start — the same per-job cost the `swift-ci` image already exists to
  remove, and a hard failure whenever `archive.ubuntu.com` is unreachable.
  `nodejs`/`npm` are now baked into that image and the probes use it; the apt
  path remains as a guarded fallback so a caller on the plain mirror, or a run
  that beats the image rebuild, still works.

  They also now save and restore a probe-owned build cache when the shared
  swift-tests key misses. That key is written by a job in another workflow, so
  nothing could order the probes after it; a miss meant a cold Swift build, and
  re-running a probe on the same commit paid for it again every time because
  nothing the probes did ever populated a key they could read back. The shared
  key is deliberately left alone — a probe winning that race would publish a
  `.build` holding only `chickadee-server` for the swift-tests jobs to restore.

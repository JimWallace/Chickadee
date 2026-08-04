### Fixed

- **Browser probe setup retries the Ubuntu package fetch.** Installing Node and
  npm is an unauthenticated plain-HTTP fetch of ~40 packages from
  `archive.ubuntu.com`; when that mirror is unreachable the step exits 100 and
  takes the whole probe — and the required editor-smoke gate — down with it.
  Observed on PR #1264: `Unable to connect to archive.ubuntu.com`. The
  network-bound half now retries three times with a short backoff. `npm ci` is
  deliberately left outside the loop, so a genuine lockfile failure still fails
  once and clearly.

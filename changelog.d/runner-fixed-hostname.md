### Changed

- **Runner hosts: give the runner container a fixed hostname.** `deploy/README.md` now says so. The server refuses a worker ID that another hostname used in the last 90 seconds, so a recreated runner with a new random hostname could not poll for 90 seconds after each update.

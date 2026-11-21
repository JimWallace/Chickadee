### Security

- **The images no longer carry the base image's unused `pebble` binary.** The `ubuntu:26.04` base ships Canonical's pebble service manager as a loose file that no package owns, so no `apt-get upgrade` patches it. Its Go standard library (1.27.3) has CVE-2026-97054 (HIGH), which failed the image vulnerability gate on every Docker build. Nothing in Chickadee runs pebble, so the runtime stage deletes it.

### Changed

- **The deployer no longer waits for the newest release's image while an older release is ready.** When the newest release has no published image yet, the deployer deploys the newest older release that is newer than production and has one. On 2026-11-16 quick merges kept production on 0.5.964 for hours. The newest release keeps its wait clock, so a build that never publishes still reports `stuck`.

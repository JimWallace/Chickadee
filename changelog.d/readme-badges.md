### Added

- **README badges.** CI status, the coverage floor, the latest release, Swift, platforms and license join the OpenSSF Scorecard badge. Every badge but two reads its value live; the coverage floor is read from `test-coverage.yml` on main, so raising the floor raises the badge. The Swift badge is static, so `scripts/check-readme-badges.sh` (a `format-lint` step, with a guard fixture) holds it to `swift-tools-version`.

### Changed

- **npm lockfiles moved within their ranges.** Four transitive packages that
  were behind now resolve to newer patch or minor versions, with no change to a
  `package.json` range: `minimatch` 11.0.6 to 11.0.8 and `brace-expansion`
  5.0.12 to 5.0.13 (root ESLint tooling), `sanitize-html` 2.18.1 to 2.18.2 and
  `ws` 8.22.2 to 8.23.0 (`Tools/vendor`). A rerun of `scripts/setup-vendor.sh`
  produced the same bytes under `Public/vendor/`.

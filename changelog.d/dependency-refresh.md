### Changed

- **Dependabot watches npm and pip.** It covered `swift`, `docker` and
  `github-actions` only, so ESLint, Playwright, esbuild, the CodeMirror
  vendoring inputs and the JupyterLite build pins were never tracked. Swift and
  Actions updates are now grouped to keep a quiet period from producing one PR
  per transitive pin; SwiftLint is deliberately excluded from that grouping,
  because `swiftlint.sh --strict` turns a new rule in a patch release into a
  red `format-lint`.
- **Swift dependency pins refreshed.** Sixteen pins move, all patch or minor —
  Vapor 4.122.1, SwiftNIO 2.102.0, JWTKit 5.7.1, swift-log 1.15.1,
  swift-crypto 4.5.2, swift-system 1.8.1 and related. JWTKit 5.7.1 asserts that
  an HS256 key is at least its 32-byte digest size; the only key affected was an
  11-byte dummy the SSO tests sign mock ID tokens with, since the server itself
  signs with ECDSA and verifies against fetched JWKS.
- **GitHub Actions bumped past five majors** — `checkout` v7, `cache` v6,
  `setup-node` v7, `setup-python` v7, `github-script` v9, across 55 call sites.
- **ESLint 10.** `@eslint/js` becomes an explicit devDependency (ESLint 10 no
  longer hoists it, so the config failed to load at all), and the two rules its
  recommended set gained found ten real issues — seven errors thrown from a
  `catch` without a `cause`, five of them in `browser-runner.js` where the
  rewritten message is all a student sees when browser grading fails to start.
- **Vendored browser libraries re-bundled** on jszip 3.10.2 and esbuild 0.28.2,
  with Playwright 1.63 across the three probe harnesses.

### Fixed

- **`scripts/setup-vendor.sh` runs again.** The Pyodide retirement (v0.5.19)
  deleted three files the script calls and left the calls in place, plus a
  `du -sh` on a variable whose assignment went with them — an unbound-variable
  abort under `set -u`. The script that regenerates everything under
  `Public/vendor/` had been dead ever since, so no dependency bump to
  `Tools/vendor` could have been actioned.
- **The vendoring lockfiles are checked in.** `Tools/vendor/package-lock.json`
  was ignored because it "regenerates via setup-vendor.sh", which is the problem
  rather than the reason: the CodeMirror inputs are declared `^6.0.0`, so
  regenerating it is exactly what lets two runs months apart bundle different
  bytes into `Public/vendor/codemirror.js` with nothing in the diff to say so.

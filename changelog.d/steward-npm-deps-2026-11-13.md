### Changed

- **npm lockfiles move to the newest versions that their ranges permit.** The root lockfile (eslint tooling) and `Tools/vendor` move within their declared ranges, and take only releases at least 3 days old, as the cooldown in `.github/dependabot.yml` does. `@emscripten-forge/untarjs` goes from 5.3.3 to 5.4.1, and `Public/vendor` is rebuilt with `scripts/setup-vendor.sh`. No range in a `package.json` changes.

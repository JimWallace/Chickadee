# Bump behind Swift package pins (weekly)

Goal: the Swift package pins stay current. `swift-currency.yml` checks them
on Mondays at 07:15 UTC. Follow the rules in `Tools/maintenance/README.md`.

1. On latest `origin/main`, run the check that `swift-currency.yml` runs,
   for the root package and `wasm/`. If every pin is current, report that
   and stop. If an open pull request already bumps the same pins, report it
   and stop.
2. Update only the packages that are behind, one
   `swift package update <package>` per package, so nothing else moves. The
   SwiftLint plugin and JavaScriptKit land as separate pull requests
   (`.github/dependabot.yml`).
3. `swift build`, then `swift test`. Fix the fallout: warnings are errors,
   and strict concurrency and strict memory safety are on.
4. Branch `claude/swift-pins-<date>` from `origin/main`. Add a changelog
   fragment, run `scripts/format-lint.sh`, and open a pull request that
   lists each pin, old and new, with a link to each release's notes. Enable
   auto-merge.
5. If a bump needs a change you cannot make safely, open the pull request as
   a draft that explains the failure, and do not enable auto-merge.
6. If a swift-currency issue is open, comment on it with the pull request.

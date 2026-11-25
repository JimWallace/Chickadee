# Contributing to Chickadee

Thank you for your interest in Chickadee. It is a student code submission and
autograding system, used in live university courses. Contributions are welcome:
bug reports, fixes, documentation, and features.

## How a change gets in

Every change from a contributor is a pull request, and the maintainer
([@JimWallace](https://github.com/JimWallace)) reviews each one before it
merges. Nothing from outside merges without that review.

1. **Open an issue first** for anything larger than a small fix, such as a new
   feature, a schema change, or a change to how grading works. A short
   discussion before the code saves rework on both sides.
2. **Fork the repository and branch** from `main`.
3. **Make the change**, with tests (see below).
4. **Open a pull request** against `main`. Describe what it changes and why,
   and link the issue.
5. **Review.** The maintainer may ask for changes. A merge to `main` is
   released automatically, so review is the last check before students see
   the change.

Pull requests from forks run CI, possibly after the maintainer approves the
first run.

**Security issues are not pull requests or public issues.** Report them
privately, as [SECURITY.md](SECURITY.md) describes.

## Set up

The [Local development](README.md#local-development) section of the README
covers the toolchain (Swift 6.4), the PostgreSQL test database, and running
the server and the runner.

## Before you open a pull request

Run these from the repository root. The tests need the PostgreSQL test
database from the README.

```bash
scripts/format.sh
scripts/format-lint.sh
swift test
```

`scripts/format.sh` formats the Swift code. `scripts/format-lint.sh` runs every
check that the CI `format-lint` job runs (formatting, SwiftLint in strict mode,
and the repository guards). `swift test` runs the test suites. CI runs all of
them on your pull request too, and it must be green before review.

## Rules the code follows

The full rules are in [CLAUDE.md](CLAUDE.md) and the `CLAUDE.md` file in each
area's directory. They are written for Claude Code, and they bind human
contributors equally. The ones that most often matter:

- **Tests come with the change.** A fix includes a test that fails without it.
  A feature includes tests for its behaviour. Use Swift Testing (`@Suite`,
  `@Test`, `#expect`), not XCTest. See
  [docs/testing-conventions.md](docs/testing-conventions.md).
- **Swift 6, strict concurrency, strict memory safety.** Warnings are errors.
  No force unwraps outside tests, and no `@unchecked Sendable` outside a
  Fluent model.
- **Errors are domain enums**, with typed `throws` where the set of errors is
  closed.
- **No new environment variables.** Configure new behaviour with a command-line
  flag, or derive it. Ask in an issue first if a variable seems unavoidable.
- **Add a changelog fragment.** Add one file under `changelog.d/` (see
  [changelog.d/README.md](changelog.d/README.md)). Do not edit `VERSION`,
  `CHANGELOG.md`, or `Sources/Core/ChickadeeVersion.swift`: versions are
  assigned at merge.
- **UI changes** follow [docs/ui-design.md](docs/ui-design.md) and
  `Sources/APIServer/Views/CLAUDE.md`.
- **Some paths change what a student's browser has cached or how a grade is
  computed** (`scripts/contract-paths.txt`). A change there ships only in a
  minor release; CI labels it, and the maintainer schedules it.

Using an AI assistant is fine. You are responsible for the change, and the
same review applies.

## Licence

Chickadee is under the [MIT License](LICENSE). By submitting a pull request,
you agree that your contribution is licensed under it.

## Supporting the project

Chickadee is maintained by one person. If it is useful to you or your course,
you can support its development through
[GitHub Sponsors](https://github.com/sponsors/JimWallace). The **Sponsor**
button at the top of the repository page links there too.

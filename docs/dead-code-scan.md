# The weekly dead-code scan

`.github/workflows/dead-code.yml` runs Periphery Pro every Sunday. Periphery
lists the Swift declarations that nothing uses. The job is a report. No result
fails it.

The weekly dead-code review reads the report. That review is a Claude Code
scheduled task on the maintainer's machine. CI runs no model (root
`CLAUDE.md`, "Subagents and Hooks"), so the review does not run in CI.

## What the job does

1. It installs Periphery Pro from the pinned release zip and checks the zip's
   SHA-256.
2. It builds the package and its tests from source with
   `-index-store-path`, under `--build-system native`.
3. It scans that index three times, with no new build: `agent-prompt`, `json`
   and `github-markdown`.
4. It uploads the three files as the `dead-code-report` artifact, and puts the
   Markdown table in the job summary.

The scan runs on Linux because a few files have Linux-only code under
`#if os(Linux)`. A macOS scan does not compile that code, so it reports what
only that code uses as unused. The trial scan on macOS reported
`sandboxOwnProcessCount` for this reason.

The job builds from source because Periphery reads the compiler's index store.
The shared `.build` cache has no index store, and a cache hit does not
recompile.

## The options in `.periphery.yml`

- `retain_codable_properties` and `retain_assign_only_properties` are on. The
  JSON encoder reads the fields of a Vapor `Content` type, and Periphery does
  not see that read. In the first trial scan, 201 of 338 results were this
  noise.
- `retain_public` is off. The package builds three executables, and the tests
  import every module, so an unused `public` declaration is dead code.

## Results that are not dead code

Periphery does not see every use. Do not remove a result in these groups. When
a result is not dead code, add it to a baseline instead (see below).

- **`CodingKeys` enums.** Synthesized `Codable` conformance uses them.
- **Fluent model properties** (`@Field`, `@OptionalField`, `@Timestamp`,
  `@Parent`, `@Children` and the other property wrappers). Fluent reads them
  by reflection. The gamification fields are in the schema on purpose (root
  `CLAUDE.md`, "Key Design Decisions").
- **Migrations.** Fluent runs them by registration.
- **Wire-format fields.** The fields in `Tests/Fixtures/output-contract.json`
  and in the MCP output schemas are read outside Swift.
- **RunnerCore declarations that only `wasm/` uses.** `wasm/` is a separate
  Swift package that imports RunnerCore for the browser grader. The scan
  builds only the root package, so it does not see those uses. Search `wasm/`
  before you remove a RunnerCore result.
- **Test seams.** A declaration whose doc comment says that tests use it.

Parameters that a protocol or a route handler signature requires (for example
an unused `req`) are reported too. They are usually not worth a change.

## Code that only tests use

Periphery counts a use from a test as a use, because the build includes the
tests. To find code that only tests use, run a second scan with
`--exclude-tests` and compare the two result lists. Removing such code means
editing tests, which needs the maintainer's approval, so that list goes to the
maintainer and not to an unattended review.

## Baselines

A baseline records accepted results, so that later scans do not report them
again. Periphery matches an entry by module, enclosing type and name, not by
file or line. A rename makes a new result. The job does not use a baseline yet.
See https://periphery.pro/docs/baselines.

## Updating Periphery

Periphery Pro is in beta. The job pins one release by version and by the
SHA-256 of its `linux_x86_64` zip. To update it, change `PERIPHERY_VERSION` and
`PERIPHERY_SHA256` in the workflow together.

The releases are at https://github.com/periphery-pro/cli-releases/releases.
To get the hash, download the zip and hash it. For example, for
`1.0.0.beta.9`:

```bash
gh release download 1.0.0.beta.9 -R periphery-pro/cli-releases -p periphery-cli_1.0.0.beta.9_linux_x86_64.zip
```

```bash
shasum -a 256 periphery-cli_1.0.0.beta.9_linux_x86_64.zip
```

## The token

The scan needs a Periphery account. In CI it reads the `PERIPHERY_TOKEN`
repository secret. Only the `Scan` step gets it. To replace the token, create a
new one at https://periphery.pro/account and set the secret again. The command
asks for the value, so the value does not go into the shell history:

```bash
gh secret set PERIPHERY_TOKEN
```

To scan on a Mac, install Periphery Pro with Homebrew and sign in with
`periphery auth login`. The open-source `periphery` formula is a different
program, and it conflicts with Pro.

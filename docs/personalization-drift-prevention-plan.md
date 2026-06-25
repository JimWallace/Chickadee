# Plan: prevent personalization ↔ solution drift

Design + implementation plan. Self-contained for an implementing agent.

## 1. Background — the bug this prevents

A cipher lab (students implement `transpose`; the platform hands each student a
personalized `ciphertext` to decode) mis-graded ~43% of students **who had the
correct answer**.

Root cause: the `ciphertext` was produced by a personalization global-input
expression that **hand-re-implemented the cipher's block-transpose inline**, and
it diverged from the **solution's** `transpose` on one edge case — the final
partial block, when `len(plaintext) % blockSize >= 2`. Two independent
implementations of one transform drifted. It survived author-time validation
because **validation runs the reference solution against a single seed**, which
landed on a 1-char partial block where both conventions happen to agree.

## 2. Design principle

A generated input must be **a function of the graded code, computed by calling
it** — never a re-derivation. One canonical implementation (**the solution**),
consumed by the generator and by validation — a dependency DAG, not a mirror:

```
        solution (canonical: encode / transpose / composite / decomposite)
       /             |                         \
  ciphertext     validation runs            public edge-case tests
  = solution.    the solution               pin students to the
  composite(...) (across seeds)             solution's convention
```

The solution is the right canonical source (not a new shared module): it already
exists, is the readable answer key, and is **server-side / hidden from students**
— the generator runs server-side, so calling it leaks nothing (only the
ciphertext *value* ships to the browser). A shared module would be a second
artifact to keep in sync and could leak the student-implemented `transpose` if
bundled into a browser-graded assignment.

The only thing blocking `ciphertext = solution.composite(...)` today: the
solution notebook contains `{{ }}` personalization placeholders, so the extracted
`solution.py` is a `SyntaxError`, its import is silently swallowed, and `solution`
never binds → `NameError`. Fix that and the drift class closes.

## 3. Repo / workflow facts

- Swift 6.3 / Vapor. Branch off `origin/main`.
- **CI is the build/test gate** (local macOS env can't reliably `swift build`/
  `test`). Run `swift-format` locally if present, then push and watch CI; CI
  format-checks regardless.
- `gh` CLI is not assumed available — open PRs via the GitHub REST API with a
  maintainer token (snippet at the end). One PR per task; let required checks
  (incl. `editor-smoke-gate`) finish.

## 4. Tasks

### Task 1 (P0) — make `solution.py` importable from personalization expressions despite `{{ }}` placeholders

**Files**: `Sources/APIServer/Services/PersonalizationEvaluator.swift` — `evaluate`
(~L55), `supportModules` (~L75), the generated driver that does
`name = importlib.import_module(name)` for each support module incl. `solution`
(~L164–184), `spawnAndCapture` (~L230). `Sources/APIServer/Services/GlobalInputsService.swift`
— `evaluateForActingSeed` (~L186). `docs/personalization-solution-notebooks.md`.

**Problem**: `solution.py` = the solution's code cells verbatim, including
module-level `x = {{name}}`. Raw `{{…}}` is invalid Python → whole-module
`SyntaxError` → silent `ImportError` (the auto-import swallow) → `solution`
unbound → any expression calling `solution.*` raises `NameError`.

**Approach (do both; B is the safety net, A is the quality bar):**
- **A — dependency-ordered substitution (preferred):** topo-sort the expression
  DAG; resolve scalar inputs first; substitute resolved `{{name}}` values into the
  `solution.py` source *before* import; then evaluate expressions that reference
  `solution`. Detect cycles, error clearly.
- **B — robust quarantine (fallback / always-on):** parse top-level statements
  when building `solution.py` and drop any that fail to `compile()`, so `def`s
  still import even if a placeholder value isn't resolvable. Record and surface
  what was dropped — **do not silently swallow** like today.

**Acceptance**: `ciphertext = solution.composite(fortune, 1 + seed % 25, 2 + seed % 5)`
resolves on an assignment whose solution uses `{{ }}` placeholders. Regression
test in `Tests/APITests/PersonalizationEvaluatorTests.swift`: a solution with both
`def`s and a `{{x}}` placeholder → `solution.*` callable; a genuinely broken
solution surfaces a *named* error, not a silent downstream `NameError`.
**Server-side only** — never change what's bundled to the student/browser env.

### Task 2 (P0/P1) — validate across the seed space, not one seed

**Files**: `Sources/APIServer/Services/GlobalInputsService.swift`
(`evaluateForActingSeed` — single acting seed), `Sources/APIServer/Services/AssignmentSeedStore.swift`
(`ensureSeed`); trace the validation-submission path from `APISubmission.Kind.validation`
/ `assignment.validationSubmissionID` (`MCPStudentDataBoundary.swift`,
`GetValidationResultTool.swift`) to confirm which seed validation uses.

**Change**: at validation, run the suite against the **distinct** personalizations,
not one seed. Statically detect `seed % N` moduli; compute `lcm`; enumerate
`0..lcm-1` (cap at a few thousand). If unbounded/undetectable, **sample K seeds and
LOG that coverage is sampled** (no silent truncation). Fail validation with the
offending **seed + test name** if any seed fails.

**Acceptance**: a regression assignment whose solution/generator disagree only on a
≥2 partial-block seed **fails validation** (currently passes). Each eval is ~ms.

### Task 3 (P1, design-first) — convention-pinning edge cases as a norm

Boundary cases (partial block, empty, size-1, non-multiple length) on every
student-implemented function are what catch a wrong *solution* at validation and
force students onto one convention. Make this an authoring norm; optionally add an
author-time **warning** when a `boundary_equality` family for a student-implemented
function has no boundary inputs. Keep it a warning, not a hard block.

### Task 4 (verify) — re-point the example assignment at `solution.composite` once Task 1 ships

After Task 1 deploys, set the cipher lab's `ciphertext` to
`solution.composite(fortune, 1 + seed % 25, 2 + seed % 5)` (replacing the stopgap
inline lambda) via the content MCP, re-validate, confirm `preview_personalization`
round-trips, re-open. Confirms the fix end-to-end on a real assignment.

## 5. Related work (separate)

- The MCP eval-check's per-instructor seed lookup currently runs on the restricted
  MCP DB pool; a separate change moves it to the main pool so the least-privilege
  role needn't be granted the seeds table (see `deploy/sql/mcp-least-privilege-role.sql`).
- MCP instructions already nudge authors to reuse `solution.*`/support modules
  (separate PR).

## 6. Sequencing

Task 1 → Task 2 → Task 4 (dogfood). Task 3 optional/parallel. One PR each; CI green
before moving on.

## 7. Opening a PR without `gh`

```python
import json, os, urllib.request
token = os.environ["GITHUB_TOKEN"]  # a maintainer PAT
payload = {"title": "...", "head": "<branch>", "base": "main", "body": "..."}
req = urllib.request.Request(
    "https://api.github.com/repos/JimWallace/Chickadee/pulls",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
             "User-Agent": "pr", "X-GitHub-Api-Version": "2022-11-28"}, method="POST")
print(json.load(urllib.request.urlopen(req))["html_url"])
```

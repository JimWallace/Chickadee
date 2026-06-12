# Personalization evaluation runtime

**Status:** design note + deferred future work (targeting 0.5+). No action for
now — the current Python-on-the-server implementation is intentionally kept.

This records a design discussion about *where* and *in what language* per-student
personalization expressions are evaluated, so we don't relitigate it from scratch
later.

## What runs today

Per-student personalization lets an instructor write an `=` expression that is
evaluated per `(student, assignment)` seed — e.g.

```python
fortuneShift = 1 + seed % 25
expected     = solution.classify_bmi(weight, height)   # may import solution.py
```

These expressions are **instructor-authored Python**. They are evaluated by
`PersonalizationEvaluator` (`Sources/APIServer/Services/`), which spawns
`python3` **on the Vapor server** (`chickadee-server`). The resolved values feed
three consumers:

- `_ck_inputs.py` for worker/browser grading (pattern-family `$name` /
  `expectedVarRef`);
- `{{name}}` substitution in the student starter notebook at first open;
- `{{name}}` substitution in the **reference-solution** notebook at validation
  (so the answer key derives the same per-student value a student would).

## The architectural tension

Chickadee's stated rule is *"Swift never imports a language runtime; everything
goes through `Process` + sandbox,"* and that sandbox boundary lives at the
**runner** (`chickadee-runner`), not the web server. The personalization
evaluator is the one place the **Vapor server itself** spawns a language runtime
— and it does so **unsandboxed** (only an env-var allowlist), next to secrets
(`RUNNER_SHARED_SECRET`, DB creds, OIDC/BrightSpace keys).

So the smell isn't "Python exists" — the *graded content* (student code, test
scripts, Pyodide) is Python by definition and always will be. The smell is that
Python execution leaked from the runner tier into the server tier.

## Why it can't just be Swift

For the simple cases you *could* evaluate in Swift — but faithfully, not
trivially. `seed` is a 64-hex-char value, so `int(seed, 16)` is a **256-bit
integer**; even `1 + seed % 25` needs arbitrary-precision integers (no stdlib
BigInt in Swift), plus Python's floored modulo, int/float division, slicing,
comprehensions, and `repr()` formatting. The whole point of computing the value
is that it **matches what Python grades against**, so any semantic divergence
silently mis-grades students. Reimplementing Python semantics in Swift is a
parity-risk minefield.

For the headline case it's outright impossible: `expected = solution.foo(...)`
runs the instructor's arbitrary `solution.py`. "Converting that to Swift" means
auto-transpiling an arbitrary Python module — not a thing. The feature *is*
"run the instructor's solution to get the canonical answer," which is, by
definition, running their Python.

## The trilemma

For a **worker-graded, personalized** assignment you can have at most two of:

1. **Server spawns zero Python** (a genuinely Swift-only server).
2. **Expression source + `solution.py` never reach the runner** — today's
   deliberate property (`TestProperties.runnerSanitized()` strips
   `globalExpressions` / `sections[].expressions` precisely so solution-derived
   source like `= solution.countAdults(...)` never ships in the Job payload).
3. **Support `= solution.foo(...)` expressions** (the strongest feature).

- Today picks **2 + 3** (server evaluates; nothing leaks to runners).
- "Move eval to the runner" picks **1 + 3** (server is Swift-only, but
  expression source + the reference solution must ship to the trusted runner).
- "Restrict to a Swift-evaluable DSL" picks **1 + 2** (loses `= solution.foo()`).

A worker-graded assignment has no browser at submit time, so the value must be
computed on the server or the runner — there is no fourth corner.

## Decision (this pass)

**Defer.** Keep Python on the server for now. Rationale:

- Every assignment today is Python; Python is the most accessible language for
  the audience; the current code works.
- The right long-term answer only becomes forced when a **second language**
  (R, etc.) lands — at which point "what language is personalization in?" stops
  being "Python vs Swift" and becomes **"the assignment's own language."**

## Future direction (0.5+)

When multi-language support is on the table, evaluate personalization **in the
assignment's language, at the tier where that language already runs**:

- native **runner** (`python3`, `Rscript`, … inside its sandbox), and/or
- the **browser** (Pyodide / WebR) for first-open substitution and browser-graded
  submissions.

Swift stays the **engine/orchestrator** — it ships `{ seed, expression specs }`
and consumes resolved values — and **never the evaluator**. Net effects:

- `chickadee-server` spawns zero language runtimes.
- All language execution is consolidated behind one sandbox boundary (a security
  win — instructor expressions stop running unsandboxed next to server secrets).
- Parity is automatic: the evaluator and the grader are the same runtime in the
  same place.

This is the generalized form of "move eval to the runner." It is a deliberate,
runner-redeploy change and **requires accepting that expression source +
`solution.py` ship to the (trusted, HMAC-authed) runner** — i.e. relaxing
property **2** above. That trade is reasonable: the runner already receives the
full test suite, which typically encodes solution behavior anyway.

### Interim hardening (optional, independent of the language question)

If the server keeps evaluating in the meantime, `PersonalizationEvaluator`
should be hardened regardless: drain stdout/stderr **concurrently** with process
exit (today it reads pipes only after `waitUntilExit()`, risking a pipe-buffer
deadlock on large output) and avoid blocking a cooperative-pool thread, and run
the subprocess under the same `sandbox-exec` / `unshare` profile the runner uses.

## Related fixes that surfaced this

- **#869** first moved solution-notebook substitution into the worker *download*
  handler, which ran `python3` synchronously on a route the runner times out
  against (5 s) → `-1001` "Build failed".
- **#870** resolved personalization **once at enqueue** and cached it (value map
  on the submission row, substituted notebook in a `<zipPath>.grading` sidecar),
  making the worker poll + download routes pure I/O.
- The follow-up race fix ensured the sidecar is written **before** the
  submission becomes claimable.

All three keep eval on the server; this note is the record of the decision to
*leave* it there for now and the direction to move it later.

# First-class C++ support

C++ is the fifth `AssignmentLanguage` (`.cpp`) and the first with **no
editor kernel**: `EditorSupport.uploadOnly`. Its assignments are upload-only
(`submissionMode: "uploadOnly"`, enforced at every authoring surface) and
grade exclusively on the native worker with the course's real g++ toolchain.
This document is the design record; every load-bearing number in it was
measured before the code was written.

## The two-C++s decision

"C++ support" conflates two different products, and the design splits them:

- **Compiled C++ — this document.** The course toolchain (g++, separate
  files, a makefile when the course teaches the build model) is the point.
  It is an `AssignmentLanguage` for the *authoring* surface — pattern
  families, per-student personalization, typed literals — while grading
  rides the original shell-script contract untouched.
- **Interactive/notebook C++ (xeus-cpp, Clang-REPL)** is a separate,
  deliberately unbuilt product. The browser kernel would be a *different
  compiler* than the course toolchain, and instructor validation always
  runs on the native worker — so a browser-graded C++ would put the
  two-compiler divergence inside the designed flow, grading something other
  than what the course teaches. If a course ever wants notebook-based C++
  teaching, it is its own arc with its own Phase-0 gate (kernel probe,
  native clang-repl script contract, per-statement JIT cost), and nothing in
  this design blocks it.

The original decision memo (`docs/cpp-assignment-language-decision.md`)
recommended against `AssignmentLanguage.cpp` outright; its revisit condition
— a course asking for generated test families in C++ — was met, and two of
its three priced costs dissolved under measurement (below). The memo stands
as the record of why the *browser* half stays unbuilt.

## How a generated C++ test works

A generated case is a **POSIX shell script**: it locates the submission
(`.chickadee_student_module` hint, then a glob), copies it to
`.ck_solution.cpp`, writes its C++ source from a quoted heredoc, compiles
**one translation unit** with g++, and `exec`s the binary — which prints the
ordinary shortResult JSON and exits 0/1/2. Consequences, all deliberate:

- **No `ScriptInterpreter` case, no build strategy in Swift.** The runner
  sees a `.sh` suite entry and runs it like any other; the compile step
  lives in the generated script, beside the code it builds.
  `generatedScriptExtension` is `"sh"` — the one language whose generated
  extension is not its own, pinned with the reasoning in the conformance
  matrix (`.sh` must keep carrying no language signal).
- **Single-TU inclusion dissolves the declared-type problem.** The test
  includes `test_runtime.hpp` (the injected template runtime), optionally
  `_ck_inputs.hpp`, then the student's file with `main` renamed
  (`#define main ck_student_main`) so an intro "write a program" submission
  still exposes its functions. The student's real definitions are in scope:
  no prototype is ever declared, and overload resolution runs against what
  they actually wrote. Literals render through CTAD-era C++
  (`std::vector<long long>{...}`) and the runtime's template `ck::equal`
  compares cross-type, so the memo's declared-type-per-family schema was
  never needed.
- **A missing function is the existence guard's own FAIL** (compile failure
  → exit 1 with a named message), and an unexpected throw inside a guarded
  kind is a graded failure with the shared "unexpected exception" wording —
  never a crash.

## Measured costs (probe, g++ 13.3 / Ubuntu 24.04)

| what | cost |
|---|---|
| per-test compile, -O0 | ~0.65 s quiet, ~0.9–1.5 s under load |
| binary run | ~2 ms |
| -O2 (performanceThreshold only) | +~0.05 s |
| personalization driver (compile+run one `=` expression) | ~0.29 s |

All inside the default 10 s per-test limit with headroom.

## Kind coverage

**Pattern families: 8 of 8.** `performanceThreshold` is supportable
*because* C++ is native-only — the two-substrate timing divergence that
forces refusals elsewhere cannot arise; its wrapper compiles `-O2`.
`returnTypeCheck` matches the neutral type names ("int", "float", "str",
"bool", "list", "dict") against the value's *static* type via decltype — no
RTTI, no mangled strings.

**Notebook checks: 0 of 10, categorically.** They inspect a submitted
notebook, and C++ assignments have no notebook workflow; every kind is
refused at save time with a message saying exactly that.

**Literals: nothing may guess a type.** Scalars render with one obvious
type (`LL` suffix past int32; strings as `std::string(...)`); single-kind
arrays/objects render explicitly typed; **JSON null, mixed-kind arrays,
nested containers, and heterogeneous object values are refused at save
time** (`JSONValue.cppRenderabilityIssue` names the reason), with an
undefined-identifier backstop in the rendered text so a leak is a compile
error, never a plausible wrong value. The measured trap: `std::cmp_equal`
rejects `bool` by design, so equality promotes bools explicitly — without
that, an authored `true` was three compile errors.

**stdout capture is fd-level (dup2), not rdbuf** — printf-using students
grade the same as cout-using ones.

## Personalization

`=` expressions are C++ expressions, evaluated server-side by a driver the
evaluator runs with `sh`: the driver script compiles a generated program
(g++, ~0.3 s) whose last stdout line maps each name to the value rendered as
a **C++ literal**, written verbatim into `_ck_inputs.hpp` — one
`inline const auto name = <literal>;` per input, so every value keeps its
natural type and a missing input is a compile error (the fail-closed check
the other runtimes do with `isKey`, earlier and louder). The seed is the
shared Horner fold (base-16 over the hex digits, mod 2³¹−1), digit-for-digit
the same as R/Lua/Octave, so a student's seed is one number in every
language.

## What an instructor does today

Declare the language and mode in the setup zip's `test.properties.json`
(`"language": "cpp"`, `"submissionMode": "uploadOnly"`) or flip the mode on
the edit page; author pattern families as in any language; add hand-written
`.sh` + makefile suites for anything families don't cover (the makefile path
is unchanged and remains the home of build-model pedagogy). Students get the
upload form (which lists `requiredFiles` and accepts `.cpp`/`.h`), and the
vanity link lands there. Runners advertise C++ via the `g++ --version`
probe *plus* the compile-and-exec probe below; both images carry g++.

## The runner work directory MUST allow `exec` (measured, 2026-08)

C++ is the first language whose grading path **executes a file it just
produced**. Every other language hands a script to an interpreter, so
"the tool is installed" and "a job will run" are the same question. For C++
they are two, and the second one has a real failure mode.

The first C++ assignment ever authored end to end failed every case with:

```
publictest_bmi_exists.sh: 39: exec: ./.ck_bin_bmi_exists: Permission denied
```

The compile succeeded. The binary was `-rwxr-xr-x`, owned by the runner uid,
with `umask 0022`. `chmod +x` changed nothing, and so did copying it
elsewhere — because the cause is not permissions at all:

```
tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=262144k
```

That runner mounts `/tmp` **`noexec`**, which is a common hardening default,
and job workspaces were rooted there. `exec` returns EACCES (shell exit 126)
no matter what the file mode says. The same suites passed in CI, where the
workspace is an ordinary directory.

**The fleet is not uniform, and that is the real shape of the bug.** A
later probe of the full mount table — the first one filtered it to `/` and
`/tmp`, which is how this was missed — found the runners disagree:

| runner | `/` | `/tmp` | compiled binary runs? |
|---|---|---|---|
| hardened | overlay `ro` | `tmpfs … noexec` | no |
| default | overlay `rw` | *no separate mount* (on the overlay) | yes |

On the second runner `/data`, `/app`, `/var/tmp`, `/home/chickadee` and the
job working directory are all writable and exec-capable; only `/dev/shm` is
`noexec`. So C++ grades correctly there and fails on the hardened host.

The symptom therefore depends on **which runner claims the job**, and only
looked absolute because for a while the hardened runner was the sole one new
enough to advertise `cpp` at all — the others predated the language. Once a
second runner upgraded, the same assignment started passing, with nothing
about it changed. An earlier revision of this document said no C++ assignment
could be graded in production; that was true of the moment it was measured,
not of the system.

Claim-order-dependent grading is precisely what `RunnerLanguageGate` exists
to eliminate, which is why the fix belongs in capability discovery rather
than in an operator runbook.

Two changes follow from it, and they are deliberately a pair:

- **The runner's existing cache directory is now its work root.** Prepared
  test setups, the per-job scratch copies made from them, and the job
  workspaces all live under one directory, set by the existing
  `--test-setup-cache-dir` flag (or `RUNNER_TEST_SETUP_CACHE_DIR`). No new
  setting was added: an operator moves one directory off the `noexec` mount
  and everything follows. The default is unchanged
  (`/tmp/chickadee-runner-cache`), so nothing moves on its own.
- **The capability probe now compiles and runs a trivial program in that
  same root**, and a runner that cannot do both stops advertising `cpp`
  (`LanguageDescriptor.capabilityRequiresExecutableOutput`). The descriptor
  used to justify the version-only probe with "the generated wrappers invoke
  the same binary, so probe and invocation cannot skew" — true of `g++`
  itself, and irrelevant, because they skew on the step *after* `g++`.

The probe is what makes the misconfiguration diagnosable rather than
mysterious. Without it a runner advertises a capability it does not have,
`RunnerLanguageGate` routes every C++ job to it, and each dies with a
message that reads as a broken test script — the exact symptom the gate
exists to prevent, arriving through the one door it did not cover. With it,
an unconfigured runner simply does not claim C++ work, which is the gate's
documented fail-closed behaviour; `list_runners` showing no `cpp` capability
on a host that has g++ is then the signal that its cache directory sits on a
`noexec` mount.

**Confirmed in production (v0.5.33).** After the hardened runner restarted on
the release, its advertised profile dropped from

```
… "cpp 13.3.0", "lua 5.4.6", "octave 8.4.0", "python 3.12.3", "r 4.3.3" …
```

to

```
… "lua 5.4.6", "octave 8.4.0", "python 3.12.3", "r 4.3.3" …
```

g++ is still installed on that host; the probe compiled a binary into the
work root, could not `exec` it, and the language was withheld. Every other
capability survived, because no other language executes something it built.
C++ work now routes deterministically to a runner that can actually run it,
and the `noexec` mount stays exactly as hardened as it was — a supported
configuration rather than a silent failure.

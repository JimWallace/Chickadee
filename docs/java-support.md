# First-class Java support

Java is the seventh `AssignmentLanguage` (`.java`) and the **third upload-only**
one, after C++ and Racket: `EditorSupport.uploadOnly`, no vendored kernel,
native-worker grading only. This document is the design record; every
load-bearing number in it was measured before the code was written.

## Why upload-only

Both available arguments point the same way, which is unusual — for C++ and
Racket they point in opposite directions and the distinction is worth keeping.

- **No kernel exists.** `emscripten-forge-4x` carries no JVM kernel to vendor.
  That is Racket's reason: contingent, not principled.
- **A kernel would be the wrong compiler.** A browser JVM would grade something
  other than the course's `javac`. That is C++'s reason: a pedagogy defect no
  substrate work removes.

Because both hold, Java's upload-only answer does not hinge on which one you
believe, and a kernel appearing on the channel would not by itself change it.

## How a generated Java test works

A generated case is a **POSIX shell script**: it writes its Java source from a
quoted heredoc, compiles with `javac`, runs with `java`, and maps the result
onto the ordinary shell-script contract. No `ScriptInterpreter` case is involved
and no build strategy enters Swift — the compile step lives in the generated
script, beside the code it builds. Same shape as C++, for the same reasons.

**Why not a `.java` test.** Java 11+ runs a source file directly (`java
Test.java`), which would need no wrapper — except that single-file source mode
compiles **exactly one file**. It cannot see the student's class or
`test_runtime.java`, and the launcher has no `--source-path` (measured). The
wrapper's `javac` step can: it pulls the student's class and `_ck_inputs.java`
in from the sourcepath **on demand**, which is also why an unrelated broken
`.java` file in a submission does not fail every test the way `javac *.java`
would.

`test_runtime.java` is named on the javac command line explicitly, because its
class is `ck` and implicit lookup only finds a class in a file named for it.

Consequences that differ from C++:

- **Nothing is copied or renamed.** C++ copies the submission to
  `.ck_solution.cpp` and `#include`s it with `main` renamed. Java compiles the
  student's file as its own unit, and their `main` cannot collide because it
  lives in their class.
- **The class is named, not discovered.** Java has no free functions and a
  public class must live in a file of its own name, so a pattern family's
  `function` carries a qualified `Class.method` (`Solution.classify`). A bare
  name is refused at save time. Instance methods are refused too, for now.
- **A hand-written `.java` suite entry IS runnable**, via source mode — more
  than `.cpp` gets, and the reason Java claims its own `ScriptInterpreter` case
  while C++ leaves `.cpp` unrunnable.

## The three measured traps

### 1. `System.exit` would make every test pass

A student calling `System.exit(0)` anywhere in their own code exits the JVM with
status 0, and the wrapper would read that as a **pass — every case, silently**.

This is the hazard R (`quit()`), Lua (`os.exit`) and Octave (`exit`) each had,
with two differences: it is in the **native** path rather than a kernel, and
Java's masking mechanism (`SecurityManager`) is deprecated for removal, so there
is nothing to mask with. Every verdict in `test_runtime.java` therefore prints a
`CK_SENTINEL` line first, and the wrapper refuses a run that did not emit one —
reporting `error` (exit 2), never a pass. Printing it in the runtime rather than
in the generated test is deliberate: a renderer cannot forget it.

Asserted by `JavaRendererExecutionTests.aSubmissionCallingSystemExitIsAnErrorNotAPass`.

### 2. Boxed numeric equality is type-strict

`Integer.valueOf(1).equals(Long.valueOf(1L))` is **`false`**, and `List.equals`
and `Map.equals` inherit that elementwise. An authored expected value of `1`
compared against a student method returning `long` would be a **silent wrong
mark on a correct submission** — the highest-risk defect in the whole change,
and the direct analogue of C++'s `std::cmp_equal`-rejects-`bool` trap.

`ck.equal` compares numbers numerically (NaN equal to NaN), strings by value,
collections and Java arrays elementwise, and maps by key under the same
relation. Booleans are deliberately **not** numbers: Java's `Boolean` is not a
`Number`, so `true == 1` is false, which is what an author writing
`expected: true` means.

Asserted by `JavaRendererExecutionTests.aWiderReturnTypeStillMatchesAnAuthoredInteger`.

### 3. Setting `CLASSPATH` removes the working directory

`.` is on the default classpath **only while `CLASSPATH` is unset**; setting it
replaces the default rather than extending it. That is Lua's `LUA_PATH` trap in
a new costume, and it is the third case proving `moduleResolution` and
`workingDirectoryIsOnDefaultSearchPath` must be asked separately: Java is
`.byName("CLASSPATH")` *and* `workingDirectoryIsOnDefaultSearchPath: true`, so
the derivation correctly returns `nil` for
`supportFilesPathEnvironmentVariable`. Generated wrappers pass `-cp .`
explicitly anyway.

Measured by `LanguageDescriptorMeasurementTests`, whose Java probe compiles
rather than executes — javac's implicit source path and the JVM's class path are
the same list, defaulting to `.` and replaced by `CLASSPATH` alike.

## Literals: far less refusal than C++

C++ needed `cppRenderabilityIssue` because `[1, "two"]` has no C++ rendering.
Java has one. Mixed arrays, nesting, objects and `null` all render, so **there
is deliberately no `javaRenderabilityIssue`**. Statically typed does not imply
C++'s answer — `Object`, autoboxing and generics are what make the difference.

Three rules replace the refusal table, each a measured trap:

- **`Arrays.asList(...)`, never `List.of(...)`.** `List.of` throws
  `NullPointerException` on a null element, which would turn an authored JSON
  null into a runtime error rather than a value. One form for every array means
  the null case cannot be reached by a branch nobody tested.
- **Objects use an insertion-ordered `LinkedHashMap`**, since `Map.of` /
  `Map.ofEntries` reject null values too. Map equality is order-independent, so
  the ordering is for readable failure messages.
- **Integers render as `int` when they fit, `L`-suffixed otherwise.** Java
  widens `int` → `long` → `double` implicitly but does **not** narrow, so a
  `long`-typed literal handed to a student's `f(int x)` is a compile error.
  C++'s `LL` rule looks identical and fails in the opposite direction.

**A fourth rule, in the string encoder: never emit a backslash-`u` escape.**
Java processes unicode escapes in the *lexer*, before it knows what a string
literal is, so the escape for a newline becomes an actual line break mid-string
and the file fails to compile with "unclosed string literal". Control characters
use the named escapes and three-digit octal.

### `_ck_inputs.java`

A public class of `public static final` fields at each value's **natural** Java
type — the analogue of C++'s `inline const auto`, spelled out because Java has
no `var` for fields. A missing input is a compile error naming the identifier:
the fail-closed check the dynamic runtimes do with `isKey`, earlier and louder.

`Object` was the obvious first choice and does not compile at the call site:
Java will not pass an `Object` to a student's `f(int x)`. The type comes from
`javaDeclaredType(forLiteral:)`, which reads the rendered literal because that
is all `renderInputsFile` has — per-student values arrive from the driver as
*already-rendered Java source*. Sound because the grammar is closed: every
string reaching it was produced by `javaLiteral` or the driver's mirroring
`ckLiteral`.

## Kind coverage

**Pattern families: 9 of 9.** `performanceThreshold` is supportable for C++'s
reason — Java is native-only, so the two-substrate timing divergence that forces
refusals elsewhere cannot arise. No JIT warm-up loop: warming would time the
*optimised* method, not what a student's single graded call costs.
`returnTypeCheck` matches the **runtime** class of the boxed result against the
neutral names (`int`/`float`/`str`/`bool`/`list`/`dict`), where C++ asks the
static type via decltype — Java cannot, because a generated test binds the
result with `var` and hands it to a helper taking `Object`.

**Notebook checks: 0 of 10, categorically.** They inspect a submitted notebook
and Java assignments have no notebook workflow. Refused at save time by
`notebookCheckKindUnsupportedReason` — the same predicate the Add Test menu and
`get_server_info` read, so the refusal cannot promise what a save would reject.

## Personalization

`=` expressions are Java expressions, evaluated server-side by a driver the
evaluator runs with `sh`: it compiles a generated program with `javac` and runs
it, reporting each name mapped to the value rendered as a **Java literal**,
written verbatim into `_ck_inputs.java`. Support helpers are named on the javac
command line rather than textually included (Java has no `#include`), and need
no ordering — javac resolves declarations across every file in one invocation.
The seed is the shared Horner fold, digit-for-digit the same as R/Lua/Octave/C++
and Racket, so a student's seed is one number in every language.

## Capability matching

`interpreterProbe` is **`javac --version`**, not `java`. The real skew is a
JRE-only host: `java` succeeds there, the runner advertises Java, and every test
dies at `javac: not found` — exit 127, which reads as a broken test script and
gets debugged as one. Probing the compiler covers both binaries, since no JDK
package ships one without the other.

`--version`, not `-version`: the old form prints to **stderr** and **quotes** the
number (`openjdk version "21.0.10"`). `RunnerProfileDetector` reads both streams
and its leading-non-digit drop tolerates the quote, so either happens to parse —
`javac --version` is the answer that does not depend on either tolerance.

`capabilityRequiresExecutableOutput` is **false**, and not because Java is
uninterpreted. The property asks whether grading *executes a file it just
produced*, because a `--version` probe cannot see that; Java's artefacts are
`.class` files the JVM **reads**, which `noexec` does not block. The capability
Java can genuinely lack is the compiler, and that is what the probe covers.

## Measured costs (OpenJDK 21.0.10 / Ubuntu 24.04)

| what | cost |
|---|---|
| per-test `javac` (test + student pulled implicitly) + `java` | ~0.6 s |
| bare JVM startup | ~40 ms |
| personalization driver (compile + run one `=` expression) | ~0.6 s |
| `default-jdk` installed | ~350 MB |

All inside the default 10 s per-test limit with headroom, and alongside C++'s
~0.65 s.

## What an instructor does today

Declare the language in the setup zip's `test.properties.json`
(`"language": "java"`, `"submissionMode": "uploadOnly"`) or pick it on the
create page; author pattern families with a **qualified** `Class.method` target;
add hand-written `.java` or `.sh` suites for anything families do not cover.
Students upload `.java` files.

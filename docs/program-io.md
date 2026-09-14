# Program I/O tests (`programIO`)

`programIO` is the tenth pattern-family kind. It grades a submission as a
**whole program**: each case supplies the text the program reads from its
standard input, and the test compares what the program printed to standard
output. It is the shape a first-weeks assignment has before functions are
introduced ("read two numbers, print their sum"), and the shape Classroom 50's
`check50` grades by default.

## Authoring

A family of this kind calls no function. Each case has one argument, the
stdin text (a string, possibly empty), and a string `expected`. The family
carries one extra field, `ioComparison`:

| `ioComparison` | The case passes when |
|---|---|
| `exact` (default) | the whole output equals `expected` |
| `included` | the output contains `expected` |
| `regex` | the output matches `expected` as a regular expression (multi-line) |

Under every comparison, trailing whitespace on each line and trailing blank
lines are removed from the output before it is compared. Under `exact` the
same normalization is applied to `expected`, so `print(7)` matches an expected
of `7` with or without a final newline.

In the web editor, pick **Test a whole program → Prints the right output for
given input** from the Add Test menu. The single case column is the stdin
text. Type it verbatim; a multi-line input is entered as a JSON-quoted string
(`"3\n4\n"`), which is how the editor already shows a multi-line value in a
single-line cell. Through the MCP surface, pass `kind: "program_io"` and
`ioComparison` to `create_pattern_family`; `update_pattern_family` accepts
`ioComparison` to change it later.

Save-time refusals: more than one argument; a non-string stdin or expected;
an empty `expected` under `included` or `regex` (it would match any output);
`regex` on a Lua assignment (Lua patterns are not regular expressions); and a
regular expression that does not compile.

Per-student `$name` references are not supported by this kind.

## What the student sees

A wrong answer fails with the shared `wrong output` headline, the input, the
expectation (prefixed `output containing` or `output matching` when the
comparison is not exact) and the output. A program that raises, or exits with
a non-zero status, fails with `unexpected exception`, the output it produced
before dying and the error text. Failure detail (`docs/failure-detail.md`)
applies as for every other test.

**Prompts are output.** `input("Enter a number: ")` writes the prompt to
stdout, exactly as `python3 prog.py < input.txt > output.txt` would record
it. An author who wants to grade only the answer uses `included` or `regex`,
or writes the expected text with the prompts in it.

## How each language runs the program

The kind is deliberately in-process on every kernel language, because a
xeus kernel has no subprocess and the kind has to grade in the browser.

| Language | Input is fed by | Exit is masked by |
|---|---|---|
| Python | swapping `sys.stdin` and `builtins.input` around `runpy.run_path(..., run_name="__main__")` | catching `SystemExit` |
| R | `readline`, `readLines("stdin")` and `scan(file = "")` masked in the environment the file is sourced into (`file("stdin")` is not) | `quit`/`q` masked |
| Lua | a proxied `io` (`read`, `lines`, `stdin`) beside the `print` capture the stdout kind already uses | `os.exit` masked |
| Octave | a command-line `input()` that draws from the case's lines (`input(prompt, "s")` returns the line as text) | `exit`/`quit` masked while the program runs |
| Racket | `current-input-port` parameterized around `dynamic-require` of the module in a fresh namespace | `exit-handler` parameterized |
| C++ | a shell wrapper compiles the submission to its own binary and runs it with the text on its real stdin; a checker translation unit grades the result | not needed: a real process |
| Java | the wrapper runs the submission in source-file mode (`java Prog.java`) with the text on its real stdin | not needed: a real process |

The exit masks matter for the same reason they matter for every runtime
helper: a program that calls `exit()` after printing its answer is normal, and
without the mask that exit would end the *test* with status 0, which the
runner reads as a pass.

## The Python import rule this changed

Every Python test runs after the runtime has imported the submission as a
module (`test_runtime.load_student_modules`), which is where a whole-program
submission first executes. A top-level `input()` at that point used to read
the test process's real stdin, and a top-level `print` landed in every test's
`longResult`. The runtime now imports each submission with an empty stdin,
`input` raising `EOFError`, and both output streams captured and discarded.
The `EOFError` is recorded as that module's load error, as any import-time
exception is, and the test itself then runs the program properly under
`runpy`. The change applies to every Python assignment, not only to this kind:
an uploaded script that prints at import no longer decorates every test's
output with its banner.

## What is not built

- **stderr comparison.** Only stdout is graded. A non-zero exit reports the
  program's stderr in the failure text, but nothing compares it.
- **Interactive scripting** (feed a line, read a line, feed another). The
  input is one text supplied up front, which is what a shell redirect gives a
  program too.
- **Command-line arguments.** A case has no `argv`. A future field would need
  every in-process runner to mask its argument source (`sys.argv`,
  `commandArgs()`, `arg`, `argv()`, `current-command-line-arguments`).

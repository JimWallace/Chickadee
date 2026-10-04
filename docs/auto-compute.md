# Auto-compute in the pattern-family editor

When you fill the arguments of a case in a pattern family, the editor calls the
function in the solution notebook with those arguments and writes the result in
the Expected cell. This is auto-compute. The Expected cell then shows the
computed cue, and the cell's title is "Auto-computed from solution notebook".

The editor UI links this page from the note under the cases table. A cell
title is one phrase and a touch screen does not show it, so the advice for each
warning is here (#1991).

## Where the call runs

- **Python, R, Lua and Octave** run the call in the browser, in the same kernel
  the notebook editor uses. The solution notebook loads once, and each call
  then has a time limit.
- **C++, Racket and Java** have no browser kernel, so the server runs the call.
  The server sends back the value, or the error text.

## When auto-compute does not run

Auto-compute does not change an Expected value that you typed. It also does not
run for:

- a `$name` reference in Expected, which the server resolves for each student
  at grading time;
- the kinds whose Expected is not a return value: return type check, exception
  expected, performance threshold, variable equality and program I/O;
- a case with an empty argument that has no default value, or a `$name`
  argument that names no input.

A differential family has no Expected value: its reference implementation
gives the expected value for each case.

## When Expected shows a warning

A warning shows in the Expected cell as a "⚠" placeholder. The cell's title
names the cause in one phrase. The sections below tell you what to do.

### Solution call did not return within 5 seconds

Placeholder: "⚠ timed out after 5s".

The function did not return within the time limit for one call. Look in the
function for:

- a loop that does not stop for these arguments;
- code that waits for keyboard input, such as Python's `input()`, R's
  `readline()`, Lua's `io.read()` or Octave's `input()`;
- a calculation that is slow for these arguments.

If the call is slow on purpose, type the Expected value yourself.

### Loading the solution notebook ran longer than 30 seconds

Placeholder: "⚠ solution notebook load timed out after 30s".

Before the first call, the editor starts the kernel and runs every top-level
cell of the solution notebook. That did not end within the time limit. The time
includes the kernel start, so a slow device or a slow network can cause it.

- Look for a top-level cell that does not stop, or that waits for keyboard
  input. Put that code in a function, or remove it from the solution.
- Look for a large import or a large data file that a top-level cell reads.
- Reload the page to try again.

### Solution function returned None

Placeholder: "⚠ solution returned None". Only a Python solution gives this
warning.

The function returned `None`. The usual cause is a function that prints its
answer and returns nothing. If the test must compare printed output, use the
Stdout equality kind. Otherwise, change the function to return the value.

### Auto-compute cannot represent a value

Placeholder: "⚠ solution returned a set", or a tuple, bytes, a complex number,
a generator, an async generator or an async function. Only a Python solution
gives this warning.

A generated test compares values that JSON can hold. The value that the
function returned has no JSON form. Do one of these:

- change the solution to return a string, an integer, a float, a boolean, a
  list or a dictionary;
- type the Expected value yourself.

### Solution raised an error

Placeholder: "⚠" and the last line of the error. Title: "Solution raised:" and
the error.

The function raised an error with these arguments. Make sure that the
arguments are correct for the function. If they are, the error is in the
solution. When the function is not defined, the placeholder also shows the
first error from the solution notebook, because an earlier cell that failed
often stops the definition.

### No solution notebook

Placeholder: "⚠ no solution notebook" or "⚠ solution notebook has no code".

Auto-compute runs the solution notebook. Upload a solution notebook that
defines the function.

### Solution notebook did not load

Placeholder: "⚠ solution notebook did not load". Title: "Load failed:" and the
reason.

A network error or a kernel error stopped the load. Reload the page to try
again.

### Computed value is not JSON

Placeholder: "⚠ Computed" and the value, then "enter it here in JSON".

This comes from the server, for a language that has no browser kernel. The
server sends back the value in the language's own syntax. The editor stores it
when it is JSON or a single true, false or null value in that syntax. Any other
value is not stored, because a generated test would then compare it as text.
Type the value in Expected as JSON.

### Auto-compute unavailable here

Placeholder: "⚠" and the reason.

The server cannot compute this value. The reason in the placeholder is one of
these:

- The assignment declares no language, so there is no solution to call. Set
  the assignment's language.
- The language has no expression driver on the server.
- The kind is Stdout equality, and the language cannot capture printed output
  automatically. Type the expected output yourself.

The page can also have no route to the server for auto-compute. Type the
Expected value yourself.

### Auto-compute request failed

Placeholder: "⚠" and the error.

The request to the server did not complete, for example because of a network
error. Reload the page to try again.

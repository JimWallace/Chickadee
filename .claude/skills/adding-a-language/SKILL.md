---
name: adding-a-language
description: >
  Adds a new assignment language to Chickadee (a new AssignmentLanguage case),
  with or without an in-browser xeus kernel. Use when asked to add, support or
  spike a language such as Haskell, OCaml, JavaScript or Fortran, to vendor a
  new xeus kernel, or to finish a language that grades but cannot be authored.
---

# Adding a language

A language has two halves of very different size:

1. **The browser half** (a xeus kernel grades scripts in the browser) is about
   one day.
2. **The supported half** (an instructor can author, personalize and validate
   an assignment in the language) is most of the work.

Chickadee has one rule here: a language is supported or it is not present.
Vendoring a kernel registers it in the editor at once, so **do not vendor a
kernel unless you will finish the second half.** Spike it on a throwaway branch
instead.

The runbook is [docs/adding-a-xeus-kernel.md](../../../docs/adding-a-xeus-kernel.md).
Its last sections record what the Lua, Octave and Java runs cost. Where they
disagree with the text above them, they are the measurement.

## Choose the route first

| The language has | Route | Model to copy |
|---|---|---|
| a xeus kernel that works on emscripten-forge | editor kernel and browser grading | Lua, Octave |
| no usable kernel, or a kernel we decided against | upload-only (`submissionMode: "uploadOnly"`) | Java ([docs/java-support.md](../../../docs/java-support.md)), C++ ([docs/cpp-support.md](../../../docs/cpp-support.md)) |

A kernel that builds for wasm is not proof that it works. Read §"Availability
is not the same as working" in the runbook before you choose.

## Workflow

Copy this checklist and complete it in order:

```
Language progress:
- [ ] 1. Choose the route (table above)
- [ ] 2. Kernel route only: browser half, runbook steps 1 to 10
- [ ] 3. Add the case to Sources/Core/AssignmentLanguage.swift
- [ ] 4. Fix every site that swift build names, one layer per pass
- [ ] 5. Fix the nine sites that the compiler cannot see
- [ ] 6. Kernel route only: the browser half checklist
- [ ] 7. Fill in LanguageDescriptor and the refused check kinds
- [ ] 8. Pass every item of the done test
- [ ] 9. Answer the parity checklist
- [ ] 10. Walk the instructor path by hand on a real server
- [ ] 11. Update the language table in CLAUDE.md and the docs it names
```

**Step 4.** Do not write the worklist by hand. Add the case, then run:

```
swift build 2>&1 | grep "error:" | sort -u
```

Each pass fixes one layer (Core, then RunnerCore and Worker, then APIServer)
and shows the next. Never add a `default:` arm to a `switch` over
`AssignmentLanguage`. The exhaustive switch is what makes the compiler name the
work.

**Step 5.** The runbook section "What the compiler will *not* tell you" lists
nine sites. Each one has shipped broken at least once. Do all nine.

**Steps 8 to 10.** The runbook sections "The done test", "Parity: what
supported is not the same as" and "The last step: walk an instructor's path by
hand" hold the lists. Lua shipped resolving to Python with 3,143 tests green.
Only the walk by hand found it.

## Rules that apply on every step

- No function defaults a `language:` parameter.
  `scripts/no-language-defaults.sh` enforces this.
- A `.sh` script carries no language signal. To ask whether a language
  generates a `.sh` wrapper, read
  `LanguageDescriptor.generatesLanguagelessWrapper`.
- Nothing infers a language. See
  [docs/language-declaration.md](../../../docs/language-declaration.md).
- A runner advertises the language through its interpreter probe, and
  `RunnerLanguageGate` uses that. Test with a runner that does NOT have the
  interpreter, too. See
  [docs/runner-capability-profiles.md](../../../docs/runner-capability-profiles.md).
- Execute the generated code under the real interpreter, against a correct
  submission and a wrong one. A parse check is not enough.
- When you fix a per-language hardcode, look at the code beside it for the
  same hardcode.
- Kernel traps (masking the exit call, one quirk per kernel) are in
  `Tools/jupyterlite/CLAUDE.md`. Read it before you change `Public/jupyterlite/`
  or `Public/vendor/`.

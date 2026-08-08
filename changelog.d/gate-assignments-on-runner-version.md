### Changed

- **Language resolution is Optional, and Python resolves positively.**
  `AssignmentLanguage.resolve` answered `.python` when nothing named a
  language, so "this is Python" and "nothing here says anything" were the same
  value — Python was defined by absence at both ends to make that work
  (`gradedScriptLanguage` skipped it, so a `.py` script never matched; its
  `notebookKernelNames` was empty, so a `python3` kernelspec never matched
  either). That conflation is upstream of the silent-misroute defects in this
  area, Lua shipping green while resolving to Python among them. `resolve` and
  `rederive` now return `AssignmentLanguage?`, nil meaning "no signal names a
  language" — a legal state, since a suite of plain `.sh` scripts is the
  system's original mode. `AssignmentLanguage.default` is gone; every site that
  used it was really asking "is this Python?" and now says so, with identical
  behaviour. Sites that must produce a language regardless (notebook
  extraction, literal rendering, expression evaluation, pattern-family
  authoring) state that locally instead of inheriting it. The browser's
  generated copy of the kernel-alias sets gains `PYTHON_KERNEL_NAMES` to match,
  so `browser-runner.js` identifies a Python notebook positively and its
  unrecognised-kernel fallback is a visible branch rather than the shape of the
  tail.

### Added

- **A runner only claims a job it can actually grade (`RunnerLanguageGate`).**
  Runners upgrade independently of the auto-deployed server, so several builds
  poll at once and claim order decided which one graded a job: an assignment in
  a newer language validated green on a capable runner, then failed for the
  next student whose job an older one claimed — with a symptom (exit 127,
  "interpreter not found") that reads as a broken test script. The claim seam
  now resolves the assignment's language and refuses a runner whose advertised
  profile lacks it, so the job waits for one that can grade it. No authoring
  step is involved, and it catches strictly more than a `minimumRunnerVersion`
  gate: a current runner whose *host* lacks the interpreter never advertises it
  either. Fails open for an assignment with no language and for a runner
  advertising no profile at all (capability discovery switched off).
  `minimumRunnerVersion` remains for runner behaviour that is not observable as
  an interpreter.

- **A Language dropdown on the assignment edit page.** Sits above Submission
  Method and declares the language explicitly, for the cases derivation cannot
  reach: a suite made only of pattern families has no script on disk to sniff,
  and C++ has neither a notebook kernel nor a language-bearing generated
  extension. It writes through the same shared helpers the MCP
  `set_assignment_language` tool uses, so both surfaces share one policy and its
  three refusals. Options are built from `AssignmentLanguage.allCases`, and the
  list leads with "detect from the notebook or test scripts" — a recorded
  language outranks every content signal, so without a way back the first
  choice would be permanent.

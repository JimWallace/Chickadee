### Changed

- **The add-a-kernel runbook no longer tells you to register your kernel with a
  map that does not exist.** Step 4 still described `check-xeus-vendored.sh` as
  carrying a literal `expected_language` and instructed you to add an entry to
  it — a step that predates the guard being derived from
  `editorSupport.notebookKernel(kernelName:)`, and one the same document's
  parity checklist already listed as free. It now says there is nothing to
  register, and gives the check that matters instead: confirm the derivation
  actually lists your kernel, since a derivation over source can go partial
  without going loud. The two rules that fall out of it going partial — assert a
  derivation's completeness, and read the mapping the compiler already forces to
  be exhaustive rather than inferring one from line proximity — are recorded
  alongside the existing enumerated-not-discovered traps, together with the
  reason it stayed invisible: a guard whose answer depends on the event it runs
  under is not a guard.

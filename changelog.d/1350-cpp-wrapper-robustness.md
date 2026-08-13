### Fixed

- **Two pattern families can no longer claim the same generated filename.** Only
  family-vs-hand-written collisions were checked, so a squashed stem — the stem
  is `<familyID>_<caseKey>`, and family `a_b`/case `c` collides with family
  `a`/case `b_c` — let one family's generated files silently replace the
  other's on apply, losing a family's cases with no error. Refused at save time
  now, naming both families.
- **A reference implementation containing the generated wrapper's heredoc
  delimiter is refused at save time.** The heredoc is quoted, so `$`, backticks
  and backslashes in an instructor's reference are already inert — but a line
  reading exactly `CHICKADEE_GENERATED_SOURCE` ended it early and ran the
  remainder as shell.
- **The generated C++ wrapper quotes its own filenames**, and drops a `.ck_*`
  case arm that never matched anything (POSIX `*` does not match a leading dot,
  so the wrapper's own dotfile artefacts were never candidates) rather than
  leaving it reading as a guard.

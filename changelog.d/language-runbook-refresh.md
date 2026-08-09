### Changed

- **The add-a-language runbook covers the authoring UI, and says a seventh
  language needs no JavaScript at all.** That section exists to stop work: the
  editors clearly behave per-language, so the failure mode is going looking for
  the arm to add and re-introducing the per-language table that v0.5.36 removed
  twice. It records the derivation table, the greppable invariant, and the rule
  for adding a genuinely new fact.
- **The compiler-invisible list is nine, not eight.** Capability matching gains
  the probe's *output format* (Racket's letter-led `v8.10` defeats the version
  parser even though the probe exits 0), and generated-script dispatch is added
  as item 9 — which the `RunnerCore`/`Core` dependency direction means the
  compiler probably never will see. The runtime helper left the list: it is
  installed from `allCases` now, so omitting it is a compile error.
- The descriptor field list, the compiler-named site count (27 arms across 17
  files), and `CLAUDE.md`'s language list are current — Racket is in both, and
  `CLAUDE.md` records the authoring-language seam and the server-side
  compute-expected route.

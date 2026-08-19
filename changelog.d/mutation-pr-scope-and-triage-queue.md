### Fixed

- **The per-PR mutation job was not watching most of the code it claimed to.**
  Its `paths:` filter was written as `Sources/RunnerCore/**` when that was the
  whole sweep scope, and widening the sweep to `Sources/Core` hours later did
  not update it — so for eleven days a pull request touching only
  `Sources/Core` (8,639 lines, and 58 of the 75 survivors in the latest run)
  silently never triggered a mutation run, while the workflow's own comment
  claimed parity with `config.json`. The trigger now names all of `Sources/**`
  and lets the run-time step that already reads `include` do the deciding, so
  there is one list rather than two that must agree. A guard
  (`workflow_scope_test.py`) fails if the filter is ever narrowed below the
  configured scope again.

### Added

- **Survivors closed with a reason are now recorded where the sweep can read
  them.** `Tools/mutation/equivalent-mutants.json` holds mutants that are
  unkillable by construction, each with the argument for why nothing reaching
  the site can observe the change. Previously that reasoning lived only in a
  commit message, so an equivalent mutant returned every week indistinguishable
  from an untriaged gap. Entries are keyed on the mutation text rather than a
  line number, so one cannot drift onto a neighbouring mutant and stops
  matching the moment the code it excuses is edited; `report.py` refuses an
  entry whose reason is a label rather than an argument. This is what makes the
  survivor list a queue that can reach zero — the honest target, since no suite
  can drive the percentage to 100.
- **The per-PR report says it is a report.** The step summary now opens with
  the three legitimate answers to a survivor, including that closing one with a
  recorded reason is a real answer. `continue-on-error` already stops the job
  failing a PR; the pressure worth heading off is social, since the cheapest
  way to clear a survivor listed on your own diff is an assertion that runs the
  line without checking the result.

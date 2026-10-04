### Fixed

- **The workbench edit half works again after an in-place save (#1957).** An
  in-place save swaps the edit half for a new render. The new markup has no
  running code: a parsed script does not run, and the CSP blocks inline
  scripts. So the suite table came back with no rows, and the editors in the
  half did not respond. Now `surface-swap.js` calls one hook,
  `ChickadeeEditPage.init()`, after the swap. That function wires the new render
  and does nothing on a render that it has wired. The swap no longer re-creates
  script elements. The editors that start themselves (section inputs, global
  inputs, achievements) export an `init` that is idempotent per element. The
  "+ Add Test" buttons of a new render are upgraded, the dataset estimates are
  painted again, and the language facts follow the new seed. Listeners on
  `<body>` are bound once per document, so one click does one action. The
  workbench smoke check now makes a second action in the swapped half.

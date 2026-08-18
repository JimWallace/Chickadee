### Added

- **Every page archetype names the page to copy, and a guard keeps it worth
  copying.** The seven-row archetype table in `docs/ui-design.md` described
  skeletons without providing one, so a new page was assembled by reading the
  rulebook and imitating whichever existing page the author happened to open —
  and nothing checked archetype conformance at all, despite the rulebook
  asserting it. Each row now names one exemplar (`alerts`, `instructor-mcp`,
  `admin-user`, `account`, `register`, `assignment-edit`, `workbench`), chosen
  for fewest page-private class names and least page CSS while still showing the
  whole shape. `PageArchetypeTests` reads that column out of the table rather
  than restating it, and re-checks each exemplar against its own row. It guards
  the exemplars and nothing else: no page fails for not being one.

### Changed

- **The UI vocabulary guard redirects instead of only refusing.** A rejected
  global class is now reported alongside the catalog components its name is
  built out of (`dataset-estimate-chip` → `chip`), the affordance registry
  carries what each registered value already means rather than only its
  spelling, and hover text over budget prints the cheapest-first ladder of
  reveal idioms. The refusals are unchanged; what follows them is actionable.
- **The two markup-contract guards share one tag walker.** `LeafMarkupScanner`
  is extracted from `ListFilterMarkupTests`, which gains HTML-comment stripping
  in the move — prose about markup is no longer read as markup.

### Fixed

- **`scripts/check-ui-vocabulary.sh` is covered by the guard self-test.** It was
  the newest guard in the repo and the only one with no fixture, so all three of
  its rules were unproven. Five fixtures now demonstrate each of them failing on
  its own defect.

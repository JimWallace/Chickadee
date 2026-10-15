### Added

- **Usability heuristics and a monthly UI audit.** `docs/ui-design.md` has a new "Usability heuristics" section: eleven rules (U1 to U11) for the tasks that students, staff and admins do, with a severity scale. A new `ui-audit` agent applies them to the whole UI, using screenshots from the visual-regression harness (`run-visual.sh --capture-only`) and the source. `.github/workflows/ui-audit.yml` runs it each month and files the report as one GitHub issue. It is a report, not a gate.

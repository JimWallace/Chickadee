### Added

- **MCP personalization tools — section variables.** The content-authoring MCP
  server now exposes `update_section_variables` (and `get_suite` now returns each
  section's `variables` and `expressions`), letting an authorized agent read and
  replace a test-suite section's scoped personalization inputs. The write path
  drives the same `SectionInputsService` the web editor uses, so name/`seed`/
  cross-scope-uniqueness validation and the save-time expression eval run
  identically across surfaces.

### Added

- **`get_server_info` reports every assignment language and what it supports (#1290).** The MCP
  surface had no way to discover which languages exist: an agent learned that six notebook-check
  kinds are refused on Lua, and all ten on C++ and Racket, by having a save rejected. The tool now
  returns a `languages` array — per language, its wire token and display name, its
  script/generated/source extensions, whether it has an in-browser editor kernel or is upload-only,
  whether per-student expressions can be evaluated and by which interpreter, and exactly which
  pattern-family and notebook-check kinds it renders with the reason for every exclusion. Every
  field is derived from whatever already owns the answer — the check-kind exclusions come from the
  same predicate the save-time refusal calls, so what an agent is told and what it is allowed to
  write cannot disagree, and a seventh language appears in the payload without an edit.

### Fixed

- **The agent-facing MCP copy no longer describes a five-language world (#1290).** Five hand-typed
  language lists still stopped at `cpp` after Racket shipped — including `set_assignment_language`'s
  own description, which told agents Racket was not a legal value while its (derived) JSON schema
  accepted it. Four more tool descriptions still called personalization expressions "Python source",
  the exact defect #1288 fixed in the `initialize` instructions one language earlier and did not
  fix in the tool catalog. All of it is now interpolated from `AssignmentLanguage.allCases` via
  `MCPLanguageProse`, and `MCPLanguageCoverageTests` fails on any list in the served catalog that
  stops short of every language — scoped to the whole catalog rather than to the string someone
  happened to be looking at, which is why the first fix did not hold.

### Added

- **MCP resources: assignment test-suite manifests.** The MCP server now
  advertises the `resources` capability and implements `resources/list` /
  `resources/read`, exposing each accessible assignment's raw
  `test.properties.json` manifest at `chickadee://assignment/<publicID>/manifest`
  (`application/json`). `get_suite` remains the structured view; the resource is
  the verbatim canonical authoring spec (suites, pattern families, sections,
  required files), which an agent can read straight into context. Listing is
  confined to courses the subject can act on (admins: all non-archived; everyone
  else: their enrolments) and reads re-check course access — an inaccessible or
  unknown URI is reported identically so the URI space can't be enumerated.
  Requires the `content:read` scope. Replaces the previous placeholder that
  returned an empty list and a "no resources registered" error.

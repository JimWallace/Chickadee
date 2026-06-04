### Added

- **MCP `create_pattern_family` tool (issue #461).** Agents can now create a
  brand-new pattern family on an assignment over MCP — previously families could
  only be *created* in the browser editor (`update_pattern_family` only edits an
  existing one). Takes the family `id` / `name` / `kind` / `function` /
  `paramNames` and a `cases` list (with raw-JSON `args`/`expected` and optional
  per-student `argVarRefs` / `expectedVarRef`); it inserts the family
  contiguously within its section and runs the same synchronous structural +
  per-kind validation as the editor, rejecting a duplicate id, wrong arg count,
  or an expected of the wrong shape for the kind.

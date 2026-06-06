### Changed

- **Script create/delete CRUD shared across published and draft routes.** The
  per-file create and delete logic — filename sanitization, duplicate-name and
  pattern-family guards, variable inlining, zip write/remove, and manifest
  update — was copy-pasted between `PublishedAssignmentRoutes+ScriptCRUD` and
  `DraftAssignmentRoutes+SuiteEditing`. It now lives in shared cores
  (`createScriptInSetup` / `deleteScriptFromSetup` in `ScriptCRUDHelpers`), with
  a shared `CreateScriptBody`. The published handlers keep their support-file
  re-extraction and `editURL`; the draft handlers, which have neither students
  nor a stable route yet, keep neither. No behaviour change (net ~130 fewer
  lines in the handlers).

### Fixed

- **`preview_personalization` placeholder audit reads the student notebook.**
  The MCP preview tool's `{{placeholder}}` audit read the test-setup zip's
  starter entry, so markers added through `update_notebook` — which writes the
  standalone notebook blob, not the zip — were absent from `placeholders.used`
  even though substitution worked at student first-open. The audit now uses the
  same `notebookData(for:)` resolver as the first-open path (notebook blob with
  precedence, zip as fallback), so it reflects what students actually see.

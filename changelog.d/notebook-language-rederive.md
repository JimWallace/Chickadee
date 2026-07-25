### Fixed

- **Replacing a starter notebook re-derives the assignment language.** The
  recorded manifest language was a one-way door: a Python assignment cloned and
  converted to R kept rendering `.py`, because the sticky `.python` outranked the
  new R notebook. Replacing the starter notebook (web Save or the
  `update_notebook` MCP tool) now re-derives the language from the new notebook
  via `AssignmentLanguage.rederive` and records it when it changed — a no-op
  (byte-stable) when the language is unchanged or was never recorded.

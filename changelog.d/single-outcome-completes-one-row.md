### Fixed

- **A match report with no per-match rows completes one row, never several.** `recordMatrixMatches` completed every open row from the collection's single outcome when the report carried no `matches`. A claim can open one row per classmate, so that would have recorded a result against students the job never played. Only a lone bot or empty row completes that way; any other unreported row stays open (#1749).

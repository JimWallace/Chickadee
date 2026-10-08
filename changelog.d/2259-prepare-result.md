### Changed

- **The worker and browser result routes build a result row through one step.** Both encoded the collection, built the result row and flagged it for grade sync, and the browser copy once skipped the flag. `ResultIngestEffects.prepareResult` now does the three steps, and each route saves the row inside its own transaction or retry. Behaviour is unchanged (#2259).

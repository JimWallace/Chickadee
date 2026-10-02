### Changed

- **The browser manifest strips grader-only names through the typed manifest.** `manifestWithGraderOnlyFilesStripped` was the last manifest dictionary outside a migration: it parsed to `[String: Any]`, blanked the list and re-serialized without sorted keys, so the one case that rewrote served bytes in a third encoding. It now decodes to `TestProperties`, empties `graderOnlyFiles` and encodes with the stable encoder every other manifest write uses; the no-op cases still return the input byte for byte (#1721).

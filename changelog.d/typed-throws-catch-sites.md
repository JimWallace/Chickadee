### Changed

- **Typed throws where a caller catches one error type.** `CLAUDE.md` now states the rule: every thrown error is a domain enum, and `throws(E)` is declared where the set of errors is closed. Three functions whose callers catch one error type are now typed, so those catches need no cast. The other 70 such sites also call database, HTTP or Foundation code, and keep their casts.

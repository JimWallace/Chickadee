### Fixed

- **The one-click course copy applies the duplicate check.** The copy chose its `-COPY` code with an exact, case-sensitive match, so beside an active `cs135-copy` it made `CS135-COPY` in the same term: two active courses that answer one key. It now uses the same per-term, case-folded check as every other door (#2229).

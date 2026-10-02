### Changed

- **RunnerCore carries one copy of each trim helper, and its footer type has its own name.** Five private copies of the two whitespace trims across three files are now the two shared functions in `LineSplitting.swift`. The footer parser's value type is `FooterValue`, so it no longer shares a name with Core's public `JSONValue`. The struct the six verbatim extractors return is `ExtractedVerbatimNotebook`; it served Lua, Octave, C++, Racket and Java under an R-only name. No behaviour changed (#1724).

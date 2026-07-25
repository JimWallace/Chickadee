### Fixed

- **R test results containing a backslash, a quote, or a newline are no longer
  mangled.** The R runtime hand-formats its result JSON (base R has no
  jsonlite), and `.chickadee_json_str` got every escape wrong in one of two
  ways, each hidden until a message happened to contain the offending
  character. The backslash pass searched for a *double* backslash, so a single
  `\` passed through unescaped and the result line was invalid JSON — the
  interpreter fell back to "last line as plain text" and the student saw the
  raw `{"status":...}` blob as their result. This bit every regex-based
  `cell_contains` check, which puts backslashes in messages routinely.
  Separately, the quote / newline / CR / tab replacements were each one
  backslash too many, because `gsub(..., fixed = TRUE)` uses its replacement
  literally with no backreference processing: a quote emitted `\\"`, which
  terminates the JSON string early, and a newline emitted `\\n`, which parses
  but renders to the student as a literal `\n` instead of a line break — so
  nearly every multi-line R failure message displayed wrong. All five escapes
  are now correct and pinned by tests that run the real runtime under `Rscript`
  and parse what it prints.

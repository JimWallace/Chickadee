### Fixed

- **Seventeen recorded mutations the verifier could not replay now replay.**
  Two unrelated causes, each measured against run 32265903112 before being
  fixed. Muter re-emits a body's leading comment *after* the statement, so the
  recorded text was `[comment][statement][the same comment again]` — not a
  contiguous region of any file, which made an exact search fail for 14 of 110
  candidates; stripping that duplicate makes all 14 match exactly once. And
  three candidates were refused as ambiguous because their statement is
  byte-identical across sibling functions (`let pairs = o.sorted { $0.key <
  $1.key }` appears in all four literal renderers) — Muter's line is unreliable
  on its own but is a sound *discriminator* among exact content matches, so it
  now chooses between them, and only when one begins exactly at that line.
  There is deliberately no nearest-match fallback: picking the closest would
  mean mutating one renderer while reporting a verdict about another.

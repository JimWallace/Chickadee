### Added

- **The `formatNoise` dataset transform.** A per-student dataset can now write a deterministic share of the cells in named columns another way: with surrounding spaces, in upper case or in lower case. Trimming and case-folding gives the original value back, so the step adds cleaning work without changing any answer. Empty cells stay empty, quoted cells stay one field, and the divergence diagnostic compares folded text. It is authored through MCP `set_dataset`.

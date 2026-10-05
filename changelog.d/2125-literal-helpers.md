### Changed

- **The literal renderers share one finite-double rule and call the escaper directly (#2125).** Seven one-line string wrappers are gone, and six copies of the "a whole number gets `.0`" rule are one `finiteDoubleLiteral`. The rendered bytes do not change, so `spec_hash` does not change.

### Changed

- **Both runners now produce richer, identical result strings ("level up, not
  down").** When the browser runner was unified onto the shared Swift
  `interpretScriptOutput` (Stage 4), it dropped two bits of presentation polish
  it used to do in JS. Those are now restored *in the shared interpreter*, so
  the native worker gains them too: (1) the redundant `"<test>: "` label prefix
  is stripped from the one-line `shortResult` (the test name is already the row
  heading), and (2) a footer `traceback` field (from `test_runtime`'s
  `errored(err=…)`) is surfaced as the `longResult`. Pinned for both runners by
  the shared `output-contract.json` fixture (`OutputContractTests` for native;
  the wasm-backed `output-contract.test.mjs` for the browser).

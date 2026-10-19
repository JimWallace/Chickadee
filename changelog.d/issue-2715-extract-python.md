### Changed

- **The worker extracts Python notebooks with RunnerCore (#2715).** The generic notebook path now writes `extractPython(...).executableModule`, the same module the browser runner writes through wasm. The extracted file now has `# --- cell N ---` labels, and a notebook with no code cells gives an empty file. A code cell whose first line starts with spaces now has its statements sorted the same way as in the browser. One helper now converts notebook cells for every extractor.

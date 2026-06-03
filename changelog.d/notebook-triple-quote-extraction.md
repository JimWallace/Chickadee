### Fixed

- **Notebook extraction now tracks triple-quoted strings.** The per-cell
  module/`__main__` classifier (`sanitizeCellForModule` in `RunnerCore`) scanned
  lines without any notion of triple-quoted (`"""…"""` / `'''…'''`) strings, so a
  cell that parked a multi-line block — prose or a parked alternate solution —
  at module level had its interior lines re-classified as new top-level
  statements and ripped into the `if __name__` quarantine. That split the string
  into invalid Python, which the resilient per-cell loader then silently dropped,
  wiping out **every definition and variable in the cell** (e.g. a correct
  `beats = 103680` reported as "Variable `beats` is not defined", a defined `tax`
  reported as missing). The scanner now carries triple-quote and string/comment
  state across lines, so such cells grade correctly. Shared by the native worker
  and the browser (wasm) runner. *(The vendored `Public/runner-wasm` artifact
  must be regenerated with `scripts/build-runner-wasm.sh` for the browser path to
  pick this up.)*

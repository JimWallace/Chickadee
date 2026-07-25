### Fixed

- **A brand-new R notebook assignment is no longer treated as Python.** Its
  suite is empty and nothing has recorded a language yet, so the manifest alone
  answered `.python` — the instructor's first R `=` expression was handed to
  `python3` and rejected with a Python `SyntaxError`, and the first save wrote
  `.python` into the manifest, so the assignment stayed Python until someone
  hand-authored a `.R` script to flip it. The starter notebook's kernelspec is
  the only signal that exists at that point, and it now reaches every
  server-side resolution site: the suite-save path (`applyPatternFamilies`),
  Global and section inputs, `{{name}}` notebook substitution, the worker job
  payload, the browser seed endpoint, validation materialization, and MCP
  `preview_personalization`. A recorded language and an `.R` script in the suite
  still outrank the kernelspec, and the notebook is only read when neither can
  answer, so nothing changes for existing assignments and the hot paths gain no
  file read.

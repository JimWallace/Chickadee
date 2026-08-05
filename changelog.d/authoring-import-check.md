### Added

- **Saving a browser-graded Python test now fails if the grading environment
  cannot satisfy its imports (#1271).** Browser grading runs a fixed
  `chickadee-python` kernel, and the editor's `connect-src 'self'` CSP leaves no
  runtime install escape hatch, so a package that is not baked in is an
  unrecoverable `ImportError`. That used to surface at the worst possible moment:
  instructor validation is graded by the *native* worker on a full CPython, so a
  test importing `seaborn` validated green and then failed for the first student
  who submitted. The web script create/update endpoints, `PUT /suite`, and the
  MCP `author_script` tool now reject such a write, naming the module, the line,
  and the ways forward. Nothing about the previous Pyodide architecture allowed
  this — there was no fixed package set to check against.

  The check is deliberately narrow, because a false positive blocks an
  instructor from saving legitimate work: it applies only to `.py` files in
  **browser-graded** assignments (worker grading runs real `python3`, where the
  same import is fine), and it accepts anything the setup itself bundles, the
  modules the runner injects (`test_runtime`, `_ck_inputs`), student-module
  names, and any import that is guarded or function-local.

  The available set is derived from the vendored kernel's own package tarballs
  by `scripts/derive-kernel-modules.py`, not from
  `Tools/jupyterlite/environment-python.yml`. The env file states an intent that
  only becomes true after a re-vendor — which needs micromamba and network to
  `repo.prefix.dev`, so CI can never do one — and a check derived from intent
  would accept `import scipy` while the shipped kernel has none. Deriving from
  the bytes also removes the distribution-name-to-import-name problem: the
  tarball says `site-packages/sklearn`, so there is no `scikit-learn` → `sklearn`
  table to get wrong. `scripts/check-xeus-vendored.sh` fails if the derived index
  drifts from the env beside it.

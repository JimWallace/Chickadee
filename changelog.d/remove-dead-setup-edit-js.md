### Removed

- **Dead `Public/setup-edit.js` deleted.** The legacy Phase-8 "Save notebook…"
  script was no longer loaded by any template (the JupyterLite draft flow
  replaced it) and its `PUT /api/v1/testsetups/:id/assignment` call carried no
  CSRF token, so it could never have succeeded anyway — flagged by the #883
  CSRF audit. Comments listing it as a Pyodide consumer updated to match.

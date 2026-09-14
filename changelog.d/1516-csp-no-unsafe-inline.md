### Security

- **`script-src` no longer permits inline execution.** An HCL AppScan run of
  2026-09-11 reported `'unsafe-inline'` in the CSP `script-src` as a High
  (CVSS 8.2) on three URLs; the header is global, so it applied to every
  response. It is gone. The one executable inline script in the templates —
  `base.leaf`'s multipart-upload interceptor — moved to
  `/multipart-forms.js`, and the twelve `onclick=` / `onchange=` attributes
  became data attributes read by delegated listeners in `app.js`. The
  vendored JupyterLite entry points, whose inline bootstraps we do not author,
  are allowed by SHA-256 hash on `/jupyterlite/` responses only; the hashes
  are derived at startup from the bytes actually served, so re-vendoring a
  kernel carries its own allow-list. The stray-editor-tab page stays inline
  under a named hash from the same constant, because its only job is to close
  the tab the instant it paints. `'unsafe-eval'` stays — JupyterLab compiles
  JSON-schema validators at run time — and `style-src` is unchanged.

### Changed

- **The weekly ZAP baseline stops hiding CSP findings behind one another.**
  ZAP's CSP rule reports `'unsafe-eval'`, `'unsafe-inline'`, wildcard
  directives and more under a single rule id, and `.zap/rules.tsv` can only
  set a threshold per rule — so the `IGNORE` that accepted `'unsafe-eval'`
  suppressed the High above through every weekly scan. That line is now
  `WARN`, and the assertions that were being delegated to it are explicit:
  `scripts/check-security-headers.sh` gates the ZAP job on the headers a
  client actually receives, and `ContentSecurityPolicyInlineScriptTests` pins
  the policy per directive. `check-styles.sh` fails on an inline `<script>`
  or an `on*=` attribute added to a template, so the cause is caught at the
  line that introduces it rather than at the next scan.

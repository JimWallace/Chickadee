### Changed

- **Inline template JavaScript is gone; the ratchet is now an absolute rule.**
  Every page's multi-line inline `<script>` block moved into a lintable,
  testable `Public/*.js` file — per-page wiring files for the two assignment
  authoring surfaces, the admin dashboard, the runner detail page, the
  instructor assignments/students/LEARN pages and the submissions list, plus
  a shared `support-files.js` for the upload/delete flow the two authoring
  pages had forked. Templates now carry data only (`data-*` attributes and
  single-line JSON islands). Guard 3b in `scripts/check-styles.sh` becomes
  absolute: no template may open a multi-line inline script, except
  `base.leaf`'s multipart-CSRF interceptor, which keeps its own shrink-only
  line ratchet (74). The guard's counter also now recognises the
  attribute-carrying JSON seed islands as single-line elements — previously
  they leaked its in-script state and inflated the count with template prose.
  The Test Editor modal shell owns the notebook-check edit delegation both
  authoring pages had duplicated, and ESLint coverage of the moved code
  surfaced two finds: a dead `.suite-edit-upload-btn` wiring branch (nothing
  renders that class since uploads persist per-script) and an unused
  runner-count accumulator on the admin dashboard, both removed.

### Added

- **Inline `<script>` ratchet (#1135).** Total non-blank JS lines inside
  template `<script>` blocks (2,481 today) may only shrink —
  `check-styles.sh` fails CI if the count grows. Inline template JS is
  invisible to ESLint/CodeQL/tests and keeps the CSP permissive; new page
  behaviour goes in `Public/*.js`, with the template passing data via
  `data-*` attributes or a JSON island (pattern documented in
  `docs/ui-design.md`).

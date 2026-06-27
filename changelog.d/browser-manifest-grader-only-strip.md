### Security

- **Grader-only support-file names no longer leak in the browser manifest.**
  Enforcement (#1055) withholds the *contents* of `TestProperties.graderOnlyFiles`
  (option B — `docs/datasets.md`) from every student download path, but the
  browser-runner manifest endpoint (`GET /api/v1/browser-runner/testsetups/:id/manifest`)
  still served `test.properties.json` verbatim — so the `graderOnlyFiles` array
  named the reserved holdout / answer-key files to the student's browser. The
  endpoint now blanks that array before serving (`manifestWithGraderOnlyFilesStripped`);
  a strict no-op for assignments with no grader-only files (the array is returned
  byte-for-byte), and every other manifest field is preserved.

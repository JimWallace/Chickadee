### Security

- **Grader-only support files are now withheld from students (enforcement +
  authoring).** The `TestProperties.graderOnlyFiles` marker (option B in
  `docs/datasets.md`) was a foundation-only field — nothing consulted it, so a
  support file bundled for the grader (e.g. an answer-key helper like a
  `dbgen.py`, or a reserved holdout test set) was still downloadable by any
  enrolled student via the support-file endpoint, symlinked into the in-browser
  editor, and streamed in full to a browser-graded student. Enforcement now
  unions `graderOnlyFiles` into the student-facing filters at all three points:
  the student support-file download (`TestSetupRoutes.downloadSupportFile`
  blocks it), the editor symlink pass (`NotebookWorkingCopyStore` skips it), and
  the browser-runner zip download (`BrowserRunnerRoutes.downloadTestSetup`
  streams a copy with the entries removed). The trusted native-worker download
  is unchanged (it needs the file), and the file still extracts into the
  server-side `shared/` dir so personalization expressions can import it.
  `author_script` gains a `graderOnly` flag for support files to set/clear the
  mark; it requires worker grading (a browser-graded assignment can't keep a
  file from the student).

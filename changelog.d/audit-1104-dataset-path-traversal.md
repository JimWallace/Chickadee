### Security

- **Dataset file specs are validated as bare filenames (#1104).** A dataset
  spec's `file` was only checked for non-emptiness, then joined onto directory
  paths at read time (`DatasetResolver`) and at delivery time on both the
  server and the worker — so a spec like `../../.worker-secret` could read any
  server-readable file and deliver it through the browser seed endpoint, and a
  path-carrying personalized-file key could write outside the grading
  workspace. `PUT /datasets` now rejects any name with path components and
  requires it to exist among the setup zip's bundled files; the resolver, the
  JupyterLite working-copy writer, and the worker's personalized-file writer
  all guard independently via the new shared `FilenameSafety.bareFilename`.

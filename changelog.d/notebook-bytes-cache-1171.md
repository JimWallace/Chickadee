### Changed

- **Canonical notebook bytes are cached (#1171).** Every assignment open,
  browser-result ingest, and `.ipynb` submission merge previously
  re-resolved the instructor's canonical notebook — a file read or a
  serialized `unzip` subprocess per request. A bounded LRU cache (64
  entries / 128 MB, validated against the backing file's size + mtime,
  single-flighted per setup) now serves repeat opens, so a class opening
  one assignment shares a single resolution. Instructor edits invalidate
  naturally: notebook saves rewrite the flat file and suite edits repack
  the zip, refreshing the mtime either way.

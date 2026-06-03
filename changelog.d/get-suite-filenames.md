### Added

- **`get_suite` now exposes script filenames.** Each test item carries `filename` (the editable on-disk name to pass to `author_script` / `update_suite`, for hand-written scripts) and `generatedFilenames` (the read-only file(s) a pattern-family or notebook-check row produces). Previously the filename was only inferable from the overloaded `name` field for hand-written scripts and was absent entirely for generated rows.

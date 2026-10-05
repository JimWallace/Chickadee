### Fixed

- **A course export names only the files the bundle holds (#2165).** A submission whose file is gone from disk is left out of the bundle with its results, and an export whose setup zip is missing fails with a message that names the path. Before, the manifest listed the row, the staging step skipped the file with a warning, and the import then refused the whole bundle.

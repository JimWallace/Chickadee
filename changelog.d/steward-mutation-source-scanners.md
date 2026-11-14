### Changed

- **Mutation tests for the kernel import scanners.** A mutation run on `PythonImportScanner` and `RLibraryScanner` found cases where a scanner that lost track of a string or a comment still passed every test. Two new test suites now cover those string, escape and comment rules. No product code changed.

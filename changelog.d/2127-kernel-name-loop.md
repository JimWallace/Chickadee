### Changed

- **One kernel-name loop in `AssignmentLanguage` (#2127).** `fromNotebookMetadata` and `languageFromKernelNames` each looped every language over the kernel name and the language name. The first now extracts the two strings and calls the second.

### Fixed

- **A web support-file delete clears the file's marks.** It used to remove only the suite entry, so a dataset spec could name a missing file and a stale grader-only mark could block browser grading. Both deletes now call one step that clears the grader-only mark and the dataset spec (#2487).
- **The web dataset panel refuses what `set_dataset` refuses.** Both doors now run one check, so the web no longer accepts a graded script or a notebook as a dataset, or a spec with no sample size (#2487).

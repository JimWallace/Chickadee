### Changed

- **`set_assignment_language` follows the web Language select.** Both doors now call one function. Declaring an upload-only language on a notebook assignment switches it to upload-only submission and worker grading instead of refusing, and `"none"` is accepted. Both still refuse a change once generated tests exist. The tool also reports `gradingMode` (#2486).

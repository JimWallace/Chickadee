### Fixed

- **A TA can no longer change a deadline through the assignment Save form.** The form admits a TA, because a TA edits content, but it also carries the title, the dates, the LEARN assessment, the submission method, the language and the class activity, which MCP and the other web routes keep for instructors. A TA's Save that changes one of them now returns 403 and writes nothing. A TA's Save does not close the assignment. A refused submission-method change now reports the rule it breaks, not always the upload and browser-grading message (#2484).

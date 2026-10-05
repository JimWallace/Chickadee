### Changed

- **The two draft handlers read the suite files once (#2149).** `parseSaveNewAssignmentForm` and `updateNewAssignmentDraft` decoded `suiteFiles` through `MultipartFileList` and then read the same parts again through `multipartFiles`, which already handles the array and single-bare-file shapes. The decoded field and its fallback are gone; `MultipartFileList` stays for the content-item attachments. A new test posts one bare `suiteFiles` part and reads it back.

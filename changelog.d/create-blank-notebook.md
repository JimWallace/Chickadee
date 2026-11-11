### Fixed

- **"Create Blank" works again on the new-assignment page.** The multipart form interceptor resent each submit with `new FormData(form)`, which leaves out the submit button, so the hidden draft-action buttons' `draftAction` never reached the server. "Create Blank", "Create from Assignment" and "Clear" saved the draft and did nothing else. The interceptor now sends the submitter's name and value, as a native submit does.

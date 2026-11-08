### Changed

- **The notebook editor saves to the server by default (#469).** A student's work in progress on an open assignment is now kept on the server, not only in the browser, so it survives a device change or cleared site data. The `ck_server_drive=0` cookie switches one browser back to the browser-only drive. Staff authoring copies, closed assignments, submission records and previews stay on the browser drive. Files the editor may not write (a provided dataset or support file, a submission record, another user's copy) now open read-only.

### Fixed

- **A content item keeps every file that an instructor selects.** The file input on the add-material form and on the edit form of a content item had the bare name `attachmentFiles`. The server decoded several parts with that name as one file, so only the last file was stored. Both inputs are now named `attachmentFiles[]`, and each selected file is stored in order.

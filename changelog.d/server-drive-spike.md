### Added

- **Server-backed notebook drive, off by default (#469 spike).** A browser with the `ck_server_drive=1` cookie gets an editor whose notebook and kernel file writes save to the server (`PUT /jupyterlite/api/contents/…`, scoped to the caller's own folder and never through a support-file symlink) instead of the browser's IndexedDB. Every other browser is unchanged. `Tools/editor-smoke-test/notebook-server-drive-check.mjs` exercises it end to end.

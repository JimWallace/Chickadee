### Changed

- **One `ManifestCoherence` check for the manifest rules every authoring door enforces.** The zip upload, the three `setManifest*` edits and the two MCP mode tools each restated the upload-and-browser, grader-only-and-browser, opponent-and-browser and upload-only-language rules. They now ask one function, and an edit is refused only for the incoherence it introduces, never for one a legacy manifest inherits (#1713).

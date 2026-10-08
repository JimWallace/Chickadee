### Fixed

- **A suite edit no longer overwrites a concurrent manifest edit.** `PUT /suite`, the MCP suite tools, global inputs and the script create and delete read the manifest, changed the zip, and then saved with no condition, so an achievements or dataset edit that saved in between was lost with no error. A suite edit now saves only if the manifest is unchanged, and otherwise returns a conflict that asks the author to reload. A script create or delete applies its one-entry change again to the newer manifest and keeps both edits (#2485).

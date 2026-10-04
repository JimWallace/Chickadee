### Changed

- **The assignment edit save refuses through one helper (#2110).** `saveEditedAssignment` built the same error redirect five times and set the title and dates on the model by hand. One `redirectToEditForm` now builds the redirect, and `AssignmentAuthoringService.updateMetadata` writes the title, the due date and the open date, the same call the MCP update tool makes. The error text an author sees does not change.

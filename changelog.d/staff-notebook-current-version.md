### Fixed

- **Course staff always open the current starter and solution.** A staff member's editor copy of an assignment's starter or solution notebook was made on their first visit and never refreshed, so a later change (an MCP edit, another author's save, a version restore) did not reach it, and saving that copy wrote the old notebook back over the new one. Staff copies now refresh from the stored notebook whenever it differs; an unchanged copy is left alone, so in-browser edits survive a reload. Student copies, which hold their own work, are unchanged.

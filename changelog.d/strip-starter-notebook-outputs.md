### Changed

- **Starter notebooks reach students without the author's cell outputs.** Every
  write of a starter notebook (the editor's Save, Save & Validate, creating an
  assignment, a notebook upload, MCP `update_notebook`, a version restore)
  clears each code cell's outputs, execution count and timing, so students run
  each cell themselves. The author's own editor copy keeps its outputs, and the
  solution notebook is unchanged. A one-time migration,
  `StripStarterNotebookOutputs`, clears the starters stored before this; a
  starter that lives only in the setup zip is cleared when it is read. Students
  who already opened an assignment keep the copy they were given.

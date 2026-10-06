### Changed

- **One notebook cell-source reader.** Five private copies of the "join a cell's `source`" helper are gone. Every caller now uses `NotebookCellSources.cellSource`. (#2306)

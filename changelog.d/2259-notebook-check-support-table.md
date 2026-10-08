### Changed

- **The notebook-check save refusal reads the same support table as the Add Test menu.** The R, Lua and Octave refusals encoded the table a second time, with the language name and the hand-written extension typed as literals. They now ask `notebookCheckKindIsSupported`, `displayName` and the hand-written extension rule. The refusal text is unchanged (#2259).

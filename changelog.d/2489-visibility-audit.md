### Fixed

- **Every open and close by a person writes an audit row.** The web Open button, the Save close and the MCP content-edit close wrote none. The functions that change an assignment's visibility now write the row themselves, with the door the change came through (`via`) and, for a close caused by another action, the reason. The scheduled open and close are unchanged (#2489).

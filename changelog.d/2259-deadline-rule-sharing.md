### Changed

- **The student dashboard uses the server's submit and solution-reveal rules.** The dashboard rebuilt both rules by hand from its preloaded row data. The rules are now pure functions of resolved inputs (`isAssignmentOpenForViewer` and the pure `solutionVisibleToStudent`), and both the server gates and the dashboard call them, so a guard added to one cannot be missed by the other. Behaviour is unchanged (#2259).

### Added

- **Preview as student in the workbench.** The view switch has a menu of the course's students. Pick one to open the assignment notebook as that student gets it: their personalized values, read-only, with their task headers as they show before a first submission. The preview never changes the student's own notebook or submissions. See `docs/notebook-guide.md`, "Preview as student".

### Fixed

- **Save & validate after a switch between Starter and Solution saved to the wrong notebook (shipped in the previous release).** The workbench read which notebook to save when the page loaded, so after a switch to Solution it wrote the solution's content over the starter. It now saves the notebook that is open. The same switch also left the editor deaf to the page's commands, so the test cards did not come back; that is fixed too.

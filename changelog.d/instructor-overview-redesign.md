### Changed

- **The instructor Overview uses one row shape.** Assignments, unpublished setups, materials and headings each show a tile, a name with one details line, a status control, a submitted count and icon actions. Duplicate, retest and every delete moved into a ⋯ menu. Validation now shows in the details line and the status pill instead of a column.
- **One `+ Add` menu per section.** It offers Assignment and each material kind, and it replaces the `+ Add material` and `+ Create New` buttons. `+ Add Section` moved below the sections.

### Added

- **Hide or show a material from the Overview.** A visibility select on each material row changes it in one step, through `POST /instructor/content-items/:id/visibility`. TAs can use it. It is refused on an archived course.

### Fixed

- **Escape returns focus to the popup's button.** Pressing Escape on an open row menu now closes it and puts focus back on the button that opened it.

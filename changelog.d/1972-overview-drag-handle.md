### Changed

- **The Overview's row drag uses the shared drag vocabulary.** The assignment rows on the instructor Overview rendered their own `.assignment-drag-handle` grip and `.assignment-draggable` / `.dragging` row classes, styled in the page's own style block as copies of the global rules. They now use `.suite-drag-handle` and `.suite-row-dragging`, and the whole-row grab cursor is one global rule keyed on `tr[draggable="true"]`. The page style block shrinks by 15 lines (#1972).

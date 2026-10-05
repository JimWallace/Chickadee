### Fixed

- **A failed course clone removes the copied attachment directory of the content item whose row save failed (#2168).** The copy recorded the directory only after the row was saved, so a failure between the two left the files on disk. It now records the path before it writes.

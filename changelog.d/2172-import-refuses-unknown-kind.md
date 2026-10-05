### Fixed

- **Bundle import refuses an unknown content item kind or section grading mode and names it (#2172).** A bundle from a newer server imported such an item as a link in silence. The pre-check now fails the import before any row is written, with a message that names the item and the value.

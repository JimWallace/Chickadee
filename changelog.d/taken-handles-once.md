### Changed

- **The account page loads a course's taken handles once per enrollment.** `takenHandles` is the one query behind every handle draw and check, and it reads only the handle column of rows that have one. The account page passes the set to the draw and the alternates instead of loading the roster twice (#1759).

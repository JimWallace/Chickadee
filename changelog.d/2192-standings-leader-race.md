### Fixed

- **The standings-leader record follows the leader when two results land together.** Each result wrote its own standings row, read the leader without the other's row, and set the record, so the later write could name a student who was not first. The standings write and the record award now run in one transaction that locks the assignment's setup row first.

### Changed

- **A leaderboard's first view reads the course's handles once.** Each ranked student without a handle used to trigger its own read of every handle in the course, so the first view of a 300-student board ran about 300 of them. The handles are now drawn from one read per page (#2257).

### Changed

- **Best-so-far rows and composite contributions are written in one
  statement.** The leaderboard rows, the ranked class records and a student's
  composite contribution used an existence check, a conditional update, an
  insert and a retry on conflict. Each is now one `INSERT … ON CONFLICT … DO
  UPDATE … WHERE` statement: two to four round trips become one, and the
  insert-then-catch path that the SQLite backend needed is gone.

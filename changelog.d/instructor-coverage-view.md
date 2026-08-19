### Added

- **Instructors can see which items the class has collectively covered.** A "Bug
  coverage" section on the per-assignment submissions page lists every suite item
  of a contribution assignment with a found / not-found chip, who found it first,
  and when. The uncovered items are the point: a list of what the class has found
  is a scoreboard, while one that also shows what is missing is what an
  instructor acts on mid-lab. It renders only for contribution assignments, and
  needs no flag to know that — the accumulator writes coverage rows only for
  assignments declaring contribution slots, so the existence of rows is itself the
  gate, and an ordinary assignment's page is unchanged. Assembled entirely from
  the existing component vocabulary, so it adds no CSS.

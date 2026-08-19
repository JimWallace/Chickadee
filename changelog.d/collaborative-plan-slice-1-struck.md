### Changed

- **Collaborative-assignment plan: the browser-grading refusal was already built.**
  The plan's slice 1 proposed refusing `gradingMode: browser` for contribution
  assignments so seeded bugs could not be streamed to the students hunting them.
  Reading the download path found the general mechanism already in place:
  `graderOnlyFiles` marks files withheld from every student-facing path, and
  combining it with browser grading is refused at all three authoring doors,
  filtered at the download, and blanked out of the served manifest. Marking the
  variant implementations `graderOnly` is an authoring instruction, not a code
  change, so the slice is struck.

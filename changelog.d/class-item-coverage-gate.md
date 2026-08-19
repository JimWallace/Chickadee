### Changed

- **Class-wide item coverage is recorded only for contribution assignments.**
  The accumulator shipped recording a row for every passing test on every
  assignment, on the reasoning that the union is generically useful. It is not:
  an ordinary lab's passing tests are not a class-wide union, and the rows would
  accrue forever while leaving the instructor coverage view with no cheap way to
  tell a bug hunt from a normal assignment — so it would need a second signal, or
  it would render a coverage section on every instructor page. The write is now
  gated on the assignment declaring contribution slots, resolved from the starter
  notebook through `notebookBytesCache` so a deadline spike shares one resolution,
  and best-effort so a lookup failure skips accumulation rather than failing a
  student's result report. The existence of coverage rows now means "this is a
  contribution assignment".

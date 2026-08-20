### Changed

- **The submit page states which file types it takes, and enforces them.** The
  `accept` list used to union every `AssignmentLanguage`'s extensions on the
  reasoning that a browser treats it as a hint so "breadth costs nothing" — true
  of the picker, false of the student: a Racket assignment offered `.py`, `.r`,
  `.lua` and `.m` beside `.rkt`, the page never said which language it wanted,
  and a wrong type was stored and handed to the runner, where it failed as what
  looked like a broken test script. The list is now the assignment's own
  language plus `.zip` (and `.ipynb` unless the assignment is upload-only), said
  in one sentence under the drop zone, refused client-side as a courtesy and
  server-side as the gate. An assignment that declares no language keeps the
  full union, where guessing would be worse than breadth. The page also shows
  the attempt number and the deadline in force for that student.

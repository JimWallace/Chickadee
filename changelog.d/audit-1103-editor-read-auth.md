### Security

- **Instructor-editor read endpoints now authorize against the resource's own
  course (#1103).** The suite/scripts/files/achievements/datasets/
  global-variables/edit-page reads — and the draft suite/support-file reads —
  used loaders that performed no per-course check, so an active TA of one
  course could fetch another course's reference solution and secret tests by
  guessing its 6-char assignment ID (the web-editor twin of the hole #417
  Slice G closed on the API side). All read handlers now require at least a
  `.ta` role in the owning course (admin bypass, archived courses stay
  readable); the unauthorized loaders are private so unauthorized use is
  impossible outside the helper file. The per-assignment submissions and
  per-student history pages get the same gate.

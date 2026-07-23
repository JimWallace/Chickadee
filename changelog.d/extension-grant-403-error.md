### Fixed

- **TAs can now grant per-student deadline extensions.** The extension
  grant/revoke endpoints required a per-course `.instructor` role, so a TA
  clicking Save on the extension form (shown to them on the student-submissions
  page, right beside Retest and Grade override — both TA actions) got a 403. A
  per-student extension is an individual accommodation, a sibling of
  grade-override, so it now floors at `.ta` like the other per-student grading
  actions. The assignment-wide deadline (open/close/due date) stays
  instructor-only.
- **Extension/grade-override popovers no longer get cut off at the bottom of
  the page.** On the per-student submissions page these `<details>` panels sit
  inside the results table, which clips its overflow for its rounded corners —
  so on a row near the bottom the downward-opening panel (and its Save button)
  was clipped and couldn't be scrolled to. The open panel is now floated
  (`position: fixed`) and clamped to stay fully within the viewport — placed
  below its button when it fits, flipped above when it doesn't. Phones keep the
  existing in-flow panel.

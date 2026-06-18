### Changed

- **Closed assignments stay visible to enrolled students.** A published assignment that has closed at its deadline now remains on every enrolled student's dashboard (shown as `closed`, read-only) and is openable for review, instead of silently disappearing for any student who never opened it while it was open. Recent labs no longer vanish for students who missed the window — including those a platform issue locked out. Unpublished drafts (a `closed` assignment with no past due date), `preview` (staff-only) assignments, and not-yet-started (future open date) assignments stay hidden, so authoring-in-progress content never leaks. New shared helper `assignmentVisibleToStudentByState` drives the dashboard filter and the notebook read-only view gate so they can't drift; submission remains separately gated, so the widened access is strictly read-only.

### Security

- **The reference solution is now staff-gated on the student notebook route.** `GET /testsetups/:id/notebook?file=solution` previously rendered the instructor's answer-key notebook for any enrolled student who crafted the query (the guard relied on the absence of a UI link). It now returns `403` for non-instructors, closing the exposure on open assignments and preventing the closed-assignment read-only view from widening it.

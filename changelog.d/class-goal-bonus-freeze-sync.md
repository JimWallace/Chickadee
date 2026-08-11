### Fixed

- **A class-goal bonus now reaches LEARN.** The bonus a class goal awards scales
  with live class progress, but a BrightSpace push only ever happened when a new
  result, an instructor override, or the manual "Push all" flagged a row — the
  class goal's progress moving flagged nothing. So each student's LEARN grade
  froze at whatever share of the class had reached the goal *at the moment their
  own submission was graded*, and the students who submitted earliest were
  under-credited permanently, while Chickadee's own submission page and grades
  CSV (which compute the bonus live) showed the full amount. The class-goal
  sweep now re-queues every student's grade for one push when a points-rewarded
  goal **freezes at the deadline** — the moment the final bonus exists. It fires
  once per assignment, is gated on the assignment actually being bound to a LEARN
  grade item and not excluded from sync, and leaves the live window alone (a goal
  still moving would otherwise re-push the whole class every sweep). An
  assignment with no due date never freezes, so "Push all" remains the way to
  settle its bonus.

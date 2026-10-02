### Fixed

- **One grade fold on every surface.** The student's own submission-history page, the class-goal sweep, and the badge path on the dashboard and the per-student page still preferred a worker result over a browser one. A browser result at 100 % followed by a worker regrade at 90 % read as 90 % to the student and to the sweep while every staff page said 100 %. All of them now read the highest grade across every result through the folds in `BestGradePercentBySubmissionID.swift`, and the worker-first fold is gone (#1709).

### Fixed

- **An authored badge shows on the dashboard and the staff per-student page, not only on the submission page.** One function now decides the badges a submission earns, and all three pages call it. Every badge reads the raw grade. Before, an authored badge on the submission page read the grade with the class-goal bonus, so the bonus alone could earn it (#2020).

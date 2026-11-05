### Fixed

- **The LEARN tab summary reads one row per student.** It used to read every result row of a course, with every column of the result and its submission, to keep each student's latest. Postgres now picks that row with `DISTINCT ON` and returns five columns. On 65,536 submissions the old read spent 12 s sending about 35 MB to the server, and on a busy CI runner it reached the 60 s statement timeout (#2882).

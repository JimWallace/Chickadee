### Changed

- **The grades CSV export uses less server CPU.** It reads only the three roster columns that it writes, and it decodes the best-grade rows by column name. On the benchmark data set (300 students, 12 assignments), server CPU per export goes from 58 ms to 36 ms. The file does not change.

### Changed

- **One driver for the in-browser kernel workers.** The eight kernel workers (grading and auto-compute, for Python, R, Lua and Octave) now share two drivers in `xeus-kernel-shared.js`, and each worker file is a short config. A grading worker now stops its setup when the cell that sets the assignment seed fails. Before, it ignored that failure and graded every test with the wrong per-student inputs. A new protocol test drives every worker file against a fake kernel (#1963).

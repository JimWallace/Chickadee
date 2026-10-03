### Fixed

- **Auto-compute shows the solution's error on R, Lua and Octave.** A failed in-page call on those languages wrapped its already-described error in a second object, so the Expected cell read "[object Object]" instead of the error, and a timeout was not shown as one (#1994).

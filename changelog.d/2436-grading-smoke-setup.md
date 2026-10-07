### Fixed

- **The browser grading smoke installs the committed lockfile and caches its browser.** It used `npm install`, which can resolve a version other than the lockfile, and each of its eight matrix legs downloaded Chromium again. It now uses `npm ci` and caches the Playwright download on the lockfile. Its header also names Octave, which the matrix already ran. (#2436)

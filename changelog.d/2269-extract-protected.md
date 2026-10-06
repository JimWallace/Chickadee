### Security

- **A notebook can no longer be extracted over a test script.** For R, Lua, Octave and Racket a generated test has the extension a notebook is extracted to, so a submitted `publictest_x.ipynb` replaced `publictest_x.R` with the student's own code, which then passed. Extraction now skips a notebook whose output would replace a file of the test setup, and warns (#2269).

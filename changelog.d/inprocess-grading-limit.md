### Changed

- **`docs/architecture.md` states what in-process grading does not protect.** Most generated tests load the submission into the test's own process, so a submission can read the expected value of the test that runs it. It can also read every file in its working directory, which on the native worker includes every test script, the grader-only files and the per-student inputs file. The new section also states what the process boundary still protects: other students' work, the server, and the host when the runner uses `--sandbox` (#2017).

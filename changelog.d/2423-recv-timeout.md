### Fixed

- **The streamed-body CSRF test no longer crashes the API test run under load.** Its socket gave up after 10 seconds. On a loaded CI runner the test then read an empty response and shut the app down while the request was still running, which crashed the whole test process. It now waits 60 seconds and fails with a clear message if the time runs out. (#2423)

### Changed

- **The browser JS tests use the shared settle helper and fake clock.** Fifteen `.mjs` suites that settled promise chains with real `setTimeout(0)` turns or counted `Promise.resolve()` loops now call `flushMicrotasks` from `support/dom-stub.mjs`, and the freeze-watchdog and workbench-poll suites drive their timers with the shared `FakeClock`; suites whose code under test schedules a real timer keep their `setTimeout` turn.

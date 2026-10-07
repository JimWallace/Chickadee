### Fixed

- **An R test's own `tryCatch(error =)` no longer swallows `passed()`.** In the browser, the condition that stands in for `quit()` was also an error, so a test that called `passed()` inside `tryCatch(..., error = )` reported an error there and a pass under Rscript. The condition is no longer an error, so the browser and the native runner give the same result. (#2386)

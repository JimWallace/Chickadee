### Changed

- **Test the validation verdict on the assignment.** `ValidationVariantTests` now posts a primary validation result through the worker result route and checks that the assignment's `validationStatus` changes from `pending` to `passed` for an all-pass run, and to `failed` for a failed, errored or timed-out test, a failed build and a run with no tests.

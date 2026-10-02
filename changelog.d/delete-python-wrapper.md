### Changed

- **`shouldNormalizePythonSubmission` is deleted.** It was a boolean wrapper over `submissionNormalization` kept for callers that no longer existed outside six test assertions; those assert the strategy enum directly, and the runbook item that still described the predicate as "R, or else Python" now describes the enum and its precedence (#1794).

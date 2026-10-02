### Changed

- **The runner-sanitized key-set pin now sees every field.** Its fixture left `activity`, `language`, `languageDeclared`, `submissionMode`, `githubSubmission` and `githubStatusChecks` at their defaults, and a default is omitted from the encoding, so the pin could not catch any of the six shipping to runners by mistake. The fixture populates all six, and the pinned set names `language` and `languageDeclared`, which `runnerSanitized` forwards on purpose (#1747).

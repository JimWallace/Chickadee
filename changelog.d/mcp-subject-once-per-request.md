### Changed

- **An MCP call looks up its user once.** `requireEligibleSubject` ran two queries, and one write call asked it up to three times (to authorize, then to attribute the retest and the re-validation). The answer is now kept on the request. Write authorization also checked a non-admin's enrollment twice; it now checks it once, and checks it separately only for an admin, whom `evaluateCourseWrite` exempts (#1942).

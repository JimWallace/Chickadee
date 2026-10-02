### Changed

- **Two `AcademicTerm` members with no production caller are deleted.** `AcademicTerm(shortLabel:)` and `AcademicTerm.containing(_:)` were called only from Core tests; a course key is matched against `urlKey` by string equality, and the term form offers a window of years rather than a date-derived term. The doc described both as live and now does not (#1786).

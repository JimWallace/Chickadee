### Changed

- **The runner claim walk moved out of the HTTP routes file.** `ClaimedJob`,
  `BlockedCandidate`, `ClaimEvaluator`, the candidate query and the
  evaluate-and-claim walk now live in
  `Sources/APIServer/Services/WorkerClaimEvaluation.swift`. None of them is
  about HTTP; they were file-private in `WorkerJobRoutes.swift`, so nothing
  else could see or test them.

### Added

- **Coverage for the claim walk's lost-race path.** The atomic claim step is
  now injected into the walk rather than being a method on the route
  collection, which makes reachable the branch `atomicallyClaimSubmission`'s
  own documentation described as impossible to trigger deterministically
  through the HTTP endpoint: another runner claiming a candidate between our
  scan and our claim. Three tests pin it, including that a claimed job carries
  its own test setup rather than the first candidate scanned.

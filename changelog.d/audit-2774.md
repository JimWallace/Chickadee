### Changed

- **Bundle and claim logic moved out of the route files (#2774).** `CourseBundleService` now owns course bundle export and import. `WorkerJobClaim` owns the worker claim step, including the Postgres row lock. `JobOpponentSelection` owns the choice of opponents for a class activity. The routes only check the caller, parse the request and send the response. There is no change in behaviour.

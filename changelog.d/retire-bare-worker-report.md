### Removed

- **Legacy bare result body on `POST /api/v1/worker/results`.** The server now accepts only the wrapped `WorkerExecutionReport` and refuses a bare `TestOutcomeCollection` with 422. Every runner since 0.4.x sends the wrapped form, and the deployment runner floor (`0.5.0`) keeps older runners from claiming jobs, so no live runner is affected (#1249).

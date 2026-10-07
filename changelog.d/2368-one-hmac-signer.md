### Changed

- **The worker HMAC tests sign with the shared test signer.** `WorkerHMACAuthMiddlewareTests` kept a second copy of the signing code because the shared `workerHMACHeaders` could not take a fixed timestamp or nonce, which the clock-skew and replay tests need. The shared helper now takes both, and the copy is gone. (#2368)

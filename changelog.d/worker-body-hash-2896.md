### Security

- **The runner's request signature now covers the body (#2896).** The signature covered the `X-Worker-Body-SHA256` header, but nothing compared that header with the bytes received, so an attacker on the path could keep a runner's signed headers and swap a result's body. `WorkerHMACAuthMiddleware` now hashes the collected body and compares it in constant time. It also records the replay nonce only after the signature verifies, so an unauthenticated caller cannot write `worker_nonces` rows, and refuses an `X-Worker-Id` over 256 bytes.

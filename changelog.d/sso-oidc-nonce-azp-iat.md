### Security

- **SSO login checks the ID token's nonce, authorized party and issue time.** The login now sends a fresh `nonce` and refuses an ID token that does not carry it back, an `azp` that names another client (or a multi-audience token with no `azp`), and an `iat` more than five minutes in the future (OIDC Core 3.1.3.7). The test of a callback with no code now reaches the missing-code check instead of stopping at the state check.

### Security

- **The GitHub account-link callback revokes the user token when the user read fails.** The revoke ran after `GET /user`, so a throw there rethrew past it and left the token live. Both user-authorization callbacks now run their lookups through one helper, `withRevokedUserToken`, which revokes before any outcome is read (#1765).

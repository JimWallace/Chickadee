### Security

- **Browser diagnostics can no longer grow without bound (#2900).** The rate limit keyed on a client-chosen setup ID that need not exist, so a student could store a row per random ID. It now keys on the verified setup, and caps each user at 200 rows an hour. A new leased sweep deletes `client_diagnostics` rows older than 90 days; nothing removed them before.

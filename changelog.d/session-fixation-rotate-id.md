### Security

- **Rotate the session ID on login (session-fixation defense).** All three
  authentication entry points — local login, registration, and the SSO callback
  — now issue a fresh session id when the user authenticates, instead of
  authenticating onto the pre-login session id. A session cookie fixed onto a
  victim before they log in can no longer be used to ride the resulting
  authenticated session. (`Session.rotateID()`; modelled on the UWaterloo FAST
  OIDC reference, which regenerates the session post-authentication.)

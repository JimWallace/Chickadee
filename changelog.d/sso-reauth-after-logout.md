### Security

- **Logout now forces IdP re-authentication on the next sign-in (SSO
  single-logout).** Follow-on to v0.4.240, surfaced by the IRA-PIA review:
  after logging out, clicking any protected link silently logged the user
  straight back in, because Duo keeps its own SSO session alive and the
  authorization request carried no `prompt`. Logout (and the idle timeout) now
  set a short-lived, session-scoped marker cookie (`chickadee_reauth`);
  `/auth/sso/start` consumes it and appends `prompt=login`, forcing Duo to
  re-authenticate, then clears it — so normal day-to-day SSO stays one-click
  and only an explicit logout/timeout re-prompts.

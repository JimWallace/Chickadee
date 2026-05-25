### Changed

- **The login page no longer auto-initiates SSO — it shows the "Login with
  UWaterloo" button.** In SSO-only mode `/login` used to redirect straight into
  `/auth/sso/start`, which made logout look broken: opening the app after
  logging out silently re-authenticated against the IdP's still-live SSO session
  instead of showing a logged-out page (IRA-PIA finding). Signing in now takes
  an explicit click, so logout visibly takes effect. The button still runs the
  full SSO flow (including `prompt=login` after a logout). One extra click per
  sign-in is the trade-off. (`AuthRoutes.loginForm`.)

### Security

- **Send `max_age=0` alongside `prompt=login` when forcing re-authentication
  after logout.** Some IdPs (and federating IdPs like Duo→ADFS) honour
  `max_age` even when they ignore `prompt`, so sending both gives the post-logout
  re-auth the best chance of propagating to the upstream IdP as a real
  re-authentication. (`SSOAuthRoutes.ssoStart`.)

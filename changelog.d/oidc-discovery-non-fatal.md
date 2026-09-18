### Fixed

- **An unreachable identity provider no longer stops the server from starting.**
  OIDC discovery ran before the server bound its port, and any failure was
  fatal. During an IdP outage the running container kept serving on the
  configuration it already held, but every newly built container died during
  startup, never answered `/health`, and was rejected by the blue-green deploy
  gate — so the deployment could not roll forward at the one moment a fix had to
  ship. Startup now validates the OIDC environment, which stays fatal because no
  retry supplies a missing `OIDC_CLIENT_ID`, and treats the network fetch as
  best effort. A failed fetch is logged and retried when an SSO route is next
  used, behind a short cooldown so an unreachable IdP is not dialled once per
  request. SSO becomes unavailable during an outage; everything else keeps
  serving, and the server stays deployable.

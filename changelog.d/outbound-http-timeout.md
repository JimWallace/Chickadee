### Fixed

- **Every outbound HTTP call has a read timeout.** The server now sets a 60-second read timeout on the shared outbound client, and states its 30-second connect timeout explicitly. A stalled identity provider, LMS, alert webhook or dates feed can no longer hold an SSO login or a shutdown drain open with no limit (#2765).

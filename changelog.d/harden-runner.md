### Security

- **Jobs that hold a write token have an egress allowlist.** The release
  job, the Dependabot and kernel landing jobs and the image publish job run
  `step-security/harden-runner` in block mode, with telemetry off. A step
  that reaches a host outside the job's list fails, so a compromised
  dependency cannot send a token out (#3075).

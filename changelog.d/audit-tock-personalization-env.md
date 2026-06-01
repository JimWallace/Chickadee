### Security

- **Per-student personalization expressions no longer see the server's
  environment.** The subprocess that evaluates instructor-authored
  personalization expressions inherited the full server environment, so an
  expression such as `__import__('os').environ['RUNNER_SHARED_SECRET']` could
  read the worker secret, database credentials, the OIDC client secret, or
  BrightSpace keys and surface them through a substituted notebook value. The
  subprocess now receives only an explicit allowlist (`PATH`, `HOME`, locale,
  `PYTHONHOME`) plus the assignment seed and an optional support-files
  `PYTHONPATH` — never the inherited secrets.

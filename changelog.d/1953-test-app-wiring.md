### Changed

- **Three hand-built test apps now get the standard test wiring (#1953).**
  `SSOAuthFlowTests` and `AuthModeGatingTests` now build on `makeTestApp`,
  and `NotebookWebRoutesTests` adds the same registrations itself: the
  version-capture middleware, the data-export drain and the kernel
  inventory. All three now seed `appConfig`, so they do not read the
  configuration of the machine that runs them. The two OIDC callback tests
  read the callback path through `OIDCEnvConfig.fromEnvironment()`.

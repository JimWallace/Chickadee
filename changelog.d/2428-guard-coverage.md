### Fixed

- **Every guard that CI runs now needs a fixture or a stated exemption.** The coverage check read only the `format-lint` job, so `verify-jupyterlite.sh`, `check-xeus-vendored.sh`, `check-env-vendored-sync.sh` and `check-security-headers.sh` ran with nothing to show that they could fail. It now reads every workflow and composite action. The three JupyterLite guards have fixtures, and each script that is not a check, or that needs the network or a running server, has an exemption with its reason. (#2428)

### Security

- **The deploy daemon runs in a systemd sandbox.** `chickadee-deployer.service`
  makes the file system read-only except the paths the deploy writes, and
  closes the kernel interfaces it never uses. The unit takes effect when it
  is installed again on the host; `docs/zero-downtime-deploy.md` gives the
  steps and the way back (#3078).

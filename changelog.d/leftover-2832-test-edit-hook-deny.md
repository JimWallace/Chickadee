### Security

- **The test-edit hook denies an existing-test edit when no person answers prompts.** In `auto`, `dontAsk` and `bypassPermissions` mode a hook "ask" could be answered with nobody looking. The hook now returns "deny", with a reason that tells the agent to describe the edit to the maintainer and wait. Every other mode, and an event with no `permission_mode`, still asks (#2832).

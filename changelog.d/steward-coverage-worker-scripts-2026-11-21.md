### Added

- **Tests for the runner's script launch failure, its 1 MB output cap and executable helpers.** `ScriptExecutionTests` (renamed from `ScriptExecutionGapTests`) now checks that a launch that cannot start reports exit code 2 with its prefix, and that output over 1 MB is cut at the limit, marked once, and does not stop a chatty script from finishing. `ScriptInvocationTests` checks that an executable file of unknown type runs as itself. No product code changed.

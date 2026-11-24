### Fixed

- **The Swift currency step records its exit status when the check is red.** GitHub runs `shell: bash` with `-e`, so a red check ended the step before it wrote the status. The step now turns `-e` off around the check, as `repeat-test.yml` and `mutation-probe.yml` do. This completes the fix for #3270.

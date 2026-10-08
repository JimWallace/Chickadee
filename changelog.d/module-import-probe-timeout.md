### Fixed

- **A busy runner no longer stops advertising pandas.** The runner probed each Python module import with the same 5-second limit as a `--version` probe. On a loaded host, `import pandas` took longer, so the runner did not advertise pandas, and the language gate left jobs that need it in the queue with no error. Module-import probes now have a 30-second limit. The probe-detector test suite is serialized, because four parallel detections caused the same timeout in the weekly mutation sweep.

### Fixed

- **The test-edit hook follows a `cd` in the same command.** A `cd`, `pushd` or `git -C` before an in-place edit hid a relative path to an existing test, so the hook did not ask. It now resolves the path against the new directory. In auto mode the hook's "ask" is still answered without a person; #2827 lists the options for the maintainer.

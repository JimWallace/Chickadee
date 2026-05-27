### Fixed

- **Browser runner dispatches extensionless Python test scripts.** A generated
  test script with no file extension (e.g. `beats`) but a `#!/usr/bin/env python3`
  shebang was reported as `Unsupported test script type: .beats` during browser
  grading/validation, because the extension was derived as the whole filename.
  The browser runner now classifies scripts by shebang and content when there is
  no recognised extension, mirroring the worker's `ScriptInvocation` logic.

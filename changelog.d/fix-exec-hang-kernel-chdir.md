### Fixed

- **Editor kernel no longer hangs on the first cell (`exec_hang`).** The
  in-browser notebook editor booted to idle and then wedged `[*]`-forever on the
  first cell execute for ~1 in 4 students (kernel restart didn't help;
  cross-browser). **Root cause:** the JupyterLite notebook frontend sets the
  kernel's working directory to the notebook's Drive folder by running
  `os.chdir("users/<uid>/<setup>/")` on the first execute, but that folder only
  exists in the kernel's Pyodide filesystem when the DriveFS is mounted — which
  needs the service worker we disable to run SAB-only under cross-origin
  isolation. With no service worker the folder is absent, so `chdir` raises
  `FileNotFoundError`; that error is unhandled inside Pyodide's WebLoop, so the
  execute coroutine never completes and the cell hangs. (Students carrying a
  stale service-worker registration had a working DriveFS, so the folder existed
  and they never hit it — which is why the rate was partial.) **Fix:** the kernel
  startup patch now wraps `os.chdir` to create the target directory first
  (`scripts/patch-pyodide-kernel.py`). It is safe and targeted — a no-op when the
  DriveFS already provides the folder (the working majority), and it lets the
  kernel run in a folder instead of hanging when it's missing. Verified: a
  headless repro that hung 100% now passes 0/3 in ~0.5 s. Surfacing the DriveFS
  support files into that folder for the affected minority is a separate
  follow-up.

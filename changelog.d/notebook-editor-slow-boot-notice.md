### Fixed

- **Older browsers that can't run the in-browser editor now get a clear path
  instead of an endless spinner.** Some old engines — notably Safari 18.x and
  low-memory iPads — never finish booting the WebKit comlink + service-worker
  editor (the service worker won't take control and/or the JupyterLite 0.8
  frontend can't initialise). On WebKit, if the kernel hasn't come up within
  25 s, the notebook page now reveals a polite, **non-blocking** notice plus the
  `.ipynb`-upload fallback — *without* hiding the editor, so a merely-slow-but-
  healthy boot still works (it can never hide a working editor). It suggests a
  laptop/desktop or a more recent browser, and beacons `slow_boot_notice` for
  calibration. Chrome/Edge/Firefox (the SharedArrayBuffer path) are unaffected.

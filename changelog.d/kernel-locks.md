### Changed

- **The xeus kernels are built from locks, and two builds give the same
  bytes.** `scripts/lock-kernel-envs.py` locks each
  `Tools/jupyterlite/environment-*.yml` into `Tools/jupyterlite/locks/`, naming
  every package file by URL and sha256. `scripts/build-jupyterlite.sh` installs
  each kernel from its lock at a fixed path and never solves, so a rebuild no
  longer upgrades every package. The kernel binaries no longer carry a random
  build directory, every package archive is written without a time or an
  owner, and the build's task database no longer survives between builds. A
  pull request run of the re-vendor workflow now fails when the committed
  kernels are not exactly what the locks build. Publish mode locks again
  before it builds. `scripts/lock-kernel-envs.py --check` runs in the
  JupyterLite job.
- **The JupyterLite toolchain is installed with hashes.**
  `Tools/jupyterlite/requirements.in` holds the pins, and `requirements.txt` is
  compiled from it by pip-compile, with every package, transitive ones
  included, pinned and hashed. CI installs a pinned micromamba (2.10.0),
  checked by sha256, in place of `latest`.
- **The first re-vendor after this change rewrites every kernel archive once.**
  Archives keep their names unless the build already renamed them; only the
  time and owner inside each one change. Boot-time behaviour is unchanged.

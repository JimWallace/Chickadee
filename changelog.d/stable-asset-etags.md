### Fixed

- **A deploy no longer makes browsers download unchanged kernel files again.**
  The server's ETag for a static file is its mtime plus its size. The image
  build used a fresh checkout, so every file in the image had the build time,
  and each deploy gave every vendored file a new ETag. A browser then
  downloaded the kernel binaries again on its next boot (25 to 70 MB per
  language), although no byte had changed. The image build now restores each
  file's mtime from its last commit, so an ETag changes only when its file
  changes. A CI step checks the mtime in the built image.

### Changed

- **JupyterLite is its own image layer.** A change to the rest of `Public/`
  now ships about 8 MB on a deploy, not the whole 410 MB tree. A CI step
  checks that the other `Public/` layer does not hold JupyterLite again.

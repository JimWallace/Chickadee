### Fixed

- **Course-bundle import can now import Chickadee's own exports, and
  test-setup uploads match the documented size envelope (#1158).** Bundle
  import was capped by the global 10 MB body limit while exports routinely
  run to hundreds of MB — a bundle the export page produced could not be
  re-imported. The import route now accepts up to 2 GB and writes the upload
  once (the old ByteBuffer → bytes → Data chain held three full copies in
  heap). Test-setup uploads get an explicit 300 MB cap matching the 256 MB
  uncompressed zip guard, so dataset-heavy setups no longer bounce before
  validation runs.

### Changed

- **Large artifact downloads stream instead of buffering (#1158).** The
  course-bundle export, submission downloads, and the solution-notebook
  downloads now use `asyncStreamFile` (the export's temp zip is cleaned up
  after the stream completes); the export's staging copies and the upload
  path's zip subprocesses run on the blocking thread pool.

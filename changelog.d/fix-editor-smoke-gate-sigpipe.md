### Fixed

- **Editor-smoke gate no longer skips the browser grading check on large editor
  PRs.** The required `editor-smoke-gate`'s change-detection step ran
  `set -o pipefail; echo "$changed" | grep -qE "$pattern"`; on a big changed-file
  list (e.g. a full JupyterLite bundle re-vendor) `grep -q` closed the pipe
  early, `echo` took SIGPIPE, and `pipefail` made the pipeline exit non-zero even
  on a match — so the PR was misclassified as "no editor changes" and the smoke
  was skipped, turning the required gate green without ever running the editor /
  in-browser grading check. Switched to a here-string (`grep -qE … <<< "$changed"`)
  which has no upstream writer to receive SIGPIPE.

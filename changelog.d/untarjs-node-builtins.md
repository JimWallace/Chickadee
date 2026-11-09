### Fixed

- **The vendor build accepts untarjs 5.4.1.** From 5.4.1 the untarjs
  emscripten glue also targets Node, so it carries `require` calls for `fs`,
  `path` and `crypto` behind a Node-only branch, and `scripts/setup-vendor.sh`
  failed to bundle the xeus bootstrap. The three built-ins are now marked
  external; the branch never runs in the grading worker. Unblocks Dependabot
  #2918 (#2920).

### Fixed

- **Blue-green deploys now reclaim disk from superseded images.** Every cutover
  pulls a fresh multi-GB image, but `scripts/bluegreen-deploy.sh` never pruned
  the ones it replaced, so the data disk eventually filled and Postgres PANICked
  on its next write (`could not write lock file "postmaster.pid": No space left
  on device`), taking the whole site down with a 500/502. The deploy now runs
  `docker image prune -f` before each pull. Only dangling images are removed, so
  the active color and the kept-for-rollback previous color are never touched.

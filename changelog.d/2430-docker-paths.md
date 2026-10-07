### Fixed

- **The Docker build now runs on a pull request that changes its other inputs.** The path filter omitted `.dockerignore`, the `restore-git-mtimes` action and `scripts/ci-runner-cgroup-probe.sh`, so a change to one of them reached `main` without the image build. (#2430)

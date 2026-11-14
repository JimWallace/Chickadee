### Changed

- **CI builds each release image once.** `docker-build.yml` no longer builds the push to `main` of a `chore(release):` commit. The tag build of the same commit pushes the same `:latest` and `:sha-` tags, so the second build cost about 29 runner minutes per release and held up the next merge's image build.

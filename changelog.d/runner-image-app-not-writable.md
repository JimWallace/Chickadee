### Security

- **The image no longer gives `/app` to the application user.** A test script runs as that user, so on a runner without a read-only root file system a script could add files to `/app` or replace the runner binary, which then ran with the runner secret after the next restart. `/app` now stays owned by root, and only `/data` belongs to the application user. Nothing writes to `/app` at runtime: the server runs from `/data` and the runner works under `/tmp`. The image build in CI now fails if the application user can write any path under `/app`.

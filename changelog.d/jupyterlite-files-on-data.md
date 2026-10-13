### Fixed

- **The notebook page and the workbench open again in the Docker deployment.** The server writes each notebook working copy under `Public/jupyterlite/files`. Since `/app` became owned by root (#2222), the server could not create that folder, and the page answered 500. The image now links `Public/jupyterlite/files` to `/data/jupyterlite-files` on the data volume, which the entrypoint creates. The working copies also survive a redeploy now. `docker-build.yml` checks that the application user can write one.

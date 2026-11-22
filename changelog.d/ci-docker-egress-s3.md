### Fixed

- **The image build no longer fails when Docker Hub serves a layer from S3.** The egress allowlist of the `docker-build.yml` push job did not include the Docker Hub S3 blob host. On 2026-11-21, 6 runs failed at "Set up Docker Buildx", 3 of them release-tag builds that published no image. The host is now on the list.

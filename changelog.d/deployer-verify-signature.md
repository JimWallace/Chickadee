### Security

- **The deploy daemon deploys only signed images.** Before it stages a
  release, `chickadee-deployer.sh` checks with cosign that the image digest
  carries a build-provenance attestation signed by `docker-build.yml` at the
  release tag. An unsigned or wrongly signed image is refused and the release
  waits with the reason (#3069).

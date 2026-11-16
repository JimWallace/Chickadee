### Security

- **Release images are signed.** Each pushed server image carries a
  Sigstore-signed build-provenance attestation and an SBOM attestation. The
  arm64 runner image carries a provenance attestation. Each one names the
  workflow, ref and commit that built the digest, and is stored beside the
  image in GHCR (#3069).

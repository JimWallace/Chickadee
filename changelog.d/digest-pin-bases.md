### Security

- **The image base layers are pinned by digest.** Each `FROM` in the
  Dockerfile, and the BuildKit frontend, names a digest as well as a tag. A
  base image that is pushed over under the same tag no longer reaches the
  build. Dependabot moves the `FROM` digests; the frontend digest is moved
  by hand (#3079).

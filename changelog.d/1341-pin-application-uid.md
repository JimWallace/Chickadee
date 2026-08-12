### Fixed

- **Every deploy since v0.5.65 crash-looped at boot, and the cause was a user
  ID.** The image creates its application user with `useradd --system`, which
  allocates the highest free system ID counting DOWN from 999 — so the ID it
  lands on depends on how many system users the packages installed above it
  happened to create. Adding `default-jdk` for Java claimed two of them and
  moved the application user from **999 to 997**. The production data volume is
  owned by 999 and `.mcp-signing-key` is mode 0600, so the new container could
  not read its own MCP signing key: the server exited fatally before serving a
  request, `--restart unless-stopped` restarted it, `/health` never answered,
  and the blue-green gate correctly aborted every attempt for hours while the
  previous version kept serving. The UID and GID are now pinned to 999 and
  created before any package install can claim them, and the image smoke test
  asserts the UID so this cannot drift again.

  No test downstream of the image could have caught it: a fresh volume takes
  whatever UID writes it first, so the same image is healthy in seconds in CI
  and fatal on a host that already has data. The check has to be on the image
  itself, which is where it now is.

- **A failed blue-green deploy no longer deletes the evidence.** When the health
  gate failed, `bluegreen-deploy.sh` force-removed the container before anything
  read its logs — the only record of why the boot failed. Its output is now
  captured to the deploy state directory and echoed into the journal before the
  cleanup runs. The free-space line printed on every deploy was also broken by a
  quoting bug (`awk: backslash not last character on line`) and had never shown
  a value.

# A Bonus Runner on a Mac

A Mac with Apple Silicon can run an extra runner for the production server, for
example to add capacity before a deadline. It runs the Linux runner image under
Docker Desktop, in the same sandbox as a production runner, and polls the
server over HTTPS. Nothing connects to the Mac.

This is a spike. The first one, the runner `Swift` on a Mac Studio, graded a
targeted validation run correctly in 2026-11.

## What it is and is not

- The runner reports platform `linux` and architecture `arm64`, because it runs
  in Docker Desktop's Linux VM. It is not a macOS runner.
- It claims any job it can grade, like any other runner. It is a full member
  of the fleet while it runs, not a test-only runner. To aim one validation
  run at it, call MCP `run_validation` with its `runnerID`
  (`docs/runner-capability-profiles.md`, "Asking For One Runner").
- It needs no blue-green deploy. On a stop it claims no new job, finishes the
  jobs it is running and exits (`stop_grace_period`). The other runners take
  new jobs meanwhile. Updating it is "pull the new image, recreate the
  container".

## The image

`.github/workflows/runner-arm64-image.yml` builds
`ghcr.io/jimwallace/chickadee-runner` for `linux/arm64` on each release tag
from the Dockerfile's `runner` target: the language toolchains, the runner and
its entrypoint, with no server and none of `Public/`. It follows release tags, so
the image follows the version that production runs. Tags: `latest` (the newest
release), `sha-<commit>` and the release version. It is a separate package from
the production image `ghcr.io/jimwallace/chickadee`, and a failure there blocks
no deploy.

A new GHCR package can start private. If `docker compose pull` on the Mac is
refused, make the package public in its package settings on GitHub, or run
`docker login ghcr.io` on the Mac with a token that can read packages.

## Size it for Docker Desktop

Docker Desktop gives its Linux VM a fixed amount of memory (Settings, then
Resources). The runner's limits must fit inside it:

- each job may use `--job-memory-limit`, 1024 MB by default;
- the container needs `--max-jobs` x 1 GB, plus about 0.5 GB for the runner,
  plus the `/tmp` tmpfs, because tmpfs pages count against the memory limit;
- `pids_limit` must be at least `--max-jobs` x 128 + 64.

| VM memory | `--max-jobs` | `mem_limit` | `/tmp` tmpfs | `pids_limit` |
|---|---|---|---|---|
| 8 GB (the default) | 4 | 6g | 1g | 576 |
| 24 GB | 10 | 14g | 3g | 1344 |

Leave the Mac a few cores of its own if someone uses it while it grades.

## The compose file

Put it in a folder of its own, for example `~/chickadee-swift-runner`, with a
`.env` beside it that holds `RUNNER_SHARED_SECRET=<the worker secret>` (mode
0600). The admin panel shows the worker secret. The service is the `runner`
service of `docker-compose.yml` with the same hardening; only the image, the
API URL, the worker id and the sizes differ.

```yaml
services:
  runner:
    image: ghcr.io/jimwallace/chickadee-runner:latest
    container_name: chickadee-runner-swift
    hostname: swift-runner
    entrypoint: ["/app/runner-entrypoint.sh", "/bin/sh", "-lc"]
    environment:
      RUNNER_SHARED_SECRET: ${RUNNER_SHARED_SECRET:?set RUNNER_SHARED_SECRET in .env}
    user: "0:0"
    command:
      - >
        exec /app/chickadee-runner
        --api-base-url https://chickadee.uwaterloo.ca
        --worker-id Swift
        --max-jobs 4
        --sandbox
    restart: unless-stopped
    stop_grace_period: 10m
    healthcheck:
      disable: true
    cap_drop:
      - ALL
    cap_add:
      - SYS_ADMIN
      - CHOWN
      - SETUID
      - SETGID
      - SETPCAP
    security_opt:
      - no-new-privileges:true
      - seccomp=unconfined
      - apparmor=unconfined
    pids_limit: 576
    read_only: true
    tmpfs:
      - /tmp:size=1g,exec
    mem_limit: 6g
    memswap_limit: 6g
```

Start it from that folder:

```bash
docker compose up -d
```

Check that the server accepts it. A wrong secret shows as HTTP 401 "Invalid
worker signature" on every poll:

```bash
docker logs --tail 20 chickadee-runner-swift
```

Stop it. It drains its jobs first:

```bash
docker compose stop
```

## Keep it current

Use `deploy/chickadee-runner-update.sh`, as any separate runner host does
(`deploy/README.md`, "Runner hosts: keep the runner at the server's
release"). It reads the version the server reports at `/health` and moves the
runner to that release's `:sha-<commit>` build, so the runner never runs ahead
of the server and follows a rollback back. Do not run `docker compose pull` on
a timer instead: `:latest` moves when the image is built, before the server
has deployed it.

Run the script from a clone of the repository. It loads
`scripts/lib/deployment-target.sh` from beside it, so a copy of the script on
its own fails when it recreates the runner. A shallow clone in the runner
folder is enough. It needs `git`, which on a new Mac asks to install the
developer tools the first time, so run it while someone is at the Mac:

```bash
git clone --depth 1 https://github.com/JimWallace/Chickadee.git ~/chickadee-swift-runner/repo
```

The clone does not update itself. The script changes rarely; to take a change:

```bash
git -C ~/chickadee-swift-runner/repo pull --ff-only
```

Schedule it with launchd, not cron. On macOS, installing a crontab waits for a
permission dialog ("would like to administer your computer"), and from a
remote or unattended session nobody answers it. A launchd agent in the user's
own `LaunchAgents` folder needs no such permission. Save this as
`~/Library/LaunchAgents/ca.uwaterloo.chickadee-runner-update.plist`, with
`NAME` replaced by your user name. It passes `--image-repo` with the arm64
image and `--compose-dir` with the runner folder, and runs at login and every
10 minutes:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ca.uwaterloo.chickadee-runner-update</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/NAME/chickadee-swift-runner/repo/deploy/chickadee-runner-update.sh</string>
    <string>--compose-dir</string>
    <string>/Users/NAME/chickadee-swift-runner</string>
    <string>--image-repo</string>
    <string>ghcr.io/jimwallace/chickadee-runner</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/NAME/Library/Logs/chickadee-runner-update.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/NAME/Library/Logs/chickadee-runner-update.log</string>
</dict>
</plist>
```

Load it. The agent runs while the user is logged in, which Docker Desktop
needs too. After an edit to the plist, stop it (below) and load it again; a
second load of a loaded agent fails.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ca.uwaterloo.chickadee-runner-update.plist
```

Check its last run. An exit code of 0 means the runner runs the server's
release:

```bash
launchctl print gui/$(id -u)/ca.uwaterloo.chickadee-runner-update
```

Stop the updates:

```bash
launchctl bootout gui/$(id -u)/ca.uwaterloo.chickadee-runner-update
```

The script writes to the log only when it updates the runner or fails. If the
arm64 build of a release is not published yet, the pull fails, the runner
keeps its current image, and the next run tries again.

If the host already runs the script from cron, remove that crontab line. Both
together do no harm, because the script holds a lock, but one schedule is
enough.

`restart: unless-stopped` brings the runner back when Docker Desktop starts,
unless it was stopped by hand.

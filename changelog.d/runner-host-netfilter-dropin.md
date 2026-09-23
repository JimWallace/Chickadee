### Changed

- **Runner hosts need the Docker netfilter drop-in too.** `deploy/README.md` now tells operators to install `deploy/docker-restart-after-netfilter.conf` on every runner host. Without it, a daily configuration-management restart of `netfilter-persistent` deletes Docker's iptables chains, and the runner container stays `Up` but cannot reach the server. The server-host postmortem now records that cause as well as the kernel-upgrade one.

### Added

- **A health rule for "the server cannot reach anything".** When the host's
  Docker iptables chains were destroyed by an `iptables-restore` during an
  unattended kernel upgrade, container egress died instantly: SSO token
  exchanges and BrightSpace sweeps failed from the same moment, for two days,
  while all seven existing health rules stayed green — they measure the
  server's own internals, and internals were fine. `outboundEgressFailing`
  fires when several outbound calls have failed in the window and none has
  succeeded in it. The zero-successes clause is the judgement: a flaky far end
  produces a mix of outcomes, a severed network path produces failures and
  nothing else. A deployment that makes no outbound calls records nothing and
  stays green.

### Fixed

- **The deployer reported a fixed failure string for every kind of deploy
  failure.** `history.jsonl` recorded "swap aborted (new color unhealthy)" even
  when the container never started and the health gate was never reached, which
  sent an incident responder after the wrong subsystem for a day. It now records
  what the deploy run actually printed, and escalates to a `stuck` state after
  five consecutive failures of the same version — a condition nothing previously
  distinguished from a single failure.
- **Pre-deploy snapshot failures said only that they failed.** The snapshot
  script's output went to `/dev/null`, so a snapshot failing on every deploy
  reported no reason. The reason is now logged and recorded in the deploy
  history.
- **`bluegreen-deploy.sh` now refuses to deploy when Docker's `DOCKER` iptables
  chain is missing**, naming both the recovery and the prevention rather than
  failing with an error that names iptables and not the cause. Fails open where
  iptables cannot be inspected.
- **OIDC discovery no longer delays startup.** v0.5.198 made the fetch
  non-fatal but left it blocking, so an identity provider that black-holes
  packets still held the server before it bound its port — with a health gate
  waiting on that port. The fetch now resolves in the background.

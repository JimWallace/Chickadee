### Security

- **CI agent jobs are read-only.** Every CI workflow that runs a Claude agent now runs it through one composite action, `.github/actions/claude-agent`. The action gives the agent the job's own read-only token. Before, `claude-code-action` exchanged the OIDC token for a Claude GitHub App token with write access when the App was installed, so the model jobs could write although they declared read-only permissions. A separate job with no model posts every result, after `scripts/ci-agent-sanitize.sh` cleans it. Every agent has an explicit deny list. `ui-audit` no longer runs its model in a job with `issues: write`, and `ui-review` no longer posts its own comments. `scripts/check-agent-workflows.sh` in `format-lint` keeps these rules (#2711).

### Changed

- **One review workflow and one triage workflow.** `ui-review` and `interaction-review` call one reusable workflow, `agent-pr-review.yml`, so their check names now have a `ui-review /` or `interaction-review /` prefix. `nightly-failure-notes.yml` is now a part of `ci-triage.yml`. `ci-triage` does not comment on a failed visual-regression PR run, because `visual-diff-explainer` explains that failure (#2711).

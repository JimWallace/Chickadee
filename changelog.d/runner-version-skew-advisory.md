### Changed

- **Runner version-skew alert is now advisory, not a page.** The
  `runnerVersionSkew` health alert fired at `warning` severity and paged the
  operator webhook like an outage. A runner a release behind is already
  protected by the minimum-runner-version gate (it queues rather than
  mis-grades), so it is now `info` severity: it still surfaces on `/admin/alerts`
  and via the `get_health_alerts` admin tool, but no longer pages the webhook.
  Info-severity alerts are dashboard-only, and the recent-firings view labels
  them "advisory — not paged".

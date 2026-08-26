### Fixed

- **The admin dashboard's three payload-backed cards were inert for the first
  minute after every load.** Jobs Processed, Max Load and P95 Wait draw entirely
  from `GET /admin/metrics/cards`, and that fetch was wired only to a 60-second
  interval with no call on load — so until it first fired, the cards showed an
  empty sparkline and a "—" headline, and clicking them to cycle the 24h/7d/30d
  window did nothing, while they still carried `cursor: pointer` and
  `role="button"`. They now fetch on load. The Active Users card was never
  affected: the server renders its 24h bars into the markup.

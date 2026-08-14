### Changed

- **Timestamps follow one policy (audit S8).** Times that answer "how recently"
  — activity feeds, when an agent was authorized or last used, when its access
  expires — now render as "3 hours ago" with the exact time in the tooltip,
  matching the last-seen columns that already did. Audit-log and retention
  dates stay exact, deliberately. Three columns on the connected-agents tables
  had been showing raw machine timestamps and now read as plain English.

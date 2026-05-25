### Added

- **MCP authoring: `validate_assignment` tool with live SSE progress.** Watches an
  assignment's runner validation to completion and returns the outcome
  (`passed`/`failed`/`no-runner`, or `timedOut` while still pending), by
  assignment public ID — so an agent that edited the suite/notebook can wait for
  the auto-queued validation instead of hand-rolling a poll loop. When the call
  arrives over an SSE connection carrying a `progressToken`, the transport streams
  live `notifications/progress` events (queued → running → done) before the final
  result; over plain JSON (or SSE without a token) it simply bounded-waits and
  returns the outcome. This is the worker→stream bridge from the SSE roadmap: the
  watch polls the request-independent `application.db`, so it runs safely inside
  the `@Sendable` streamed-response body without touching the non-`Sendable`
  `Request`. `content:read`, course-scoped.

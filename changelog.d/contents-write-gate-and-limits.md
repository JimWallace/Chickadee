### Security

- **The editor's write routes refuse a closed assignment (#2927).** A student's save, rename or new folder in the working copy of a closed or not-yet-open assignment is refused, by the same gate as the notebook reset. An editor left open past the deadline no longer keeps saving. Course staff are not gated.
- **Storage quota and rate limit on the editor's write routes (#2926).** A save that would take a user's own files past 25 MB is refused with a 413, and more than 240 write requests a minute from one user answer 429. The quota counts only files the student wrote, not delivered datasets, support files or submission records. Each refusal logs a structured line (`jupyterlite_contents_quota_exceeded`, `jupyterlite_contents_write_rate_limited`).

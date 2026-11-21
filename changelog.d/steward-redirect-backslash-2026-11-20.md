### Security

- **The course-switch redirect no longer accepts a backslash.** The `next` value of the course-switch form refused `//host` but accepted `/\host`, which a browser reads as `//host`, so it could send a signed-in user to another site. It now uses the shared `isSafeLocalPath` check. The queued MCP sign-in return path had the same gap; no route can store such a value there today, but it now uses the same check. The editor-reset return path uses it too, in place of its own copy of the rule.

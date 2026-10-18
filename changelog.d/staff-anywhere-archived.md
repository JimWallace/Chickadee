### Security

- **A TA from a past term no longer reads every user's files.** The user-file namespace and the JupyterLite contents gave the full file tree to anyone with a staff role in any course, archived courses included. They now count only courses that are not archived, as the avatar ring does (#1756). MCP and the OAuth consent still count archived courses, so an archived course stays readable through MCP (#2663).

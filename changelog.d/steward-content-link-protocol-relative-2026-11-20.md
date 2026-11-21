### Security

- **Course content links refuse protocol-relative URLs.** A content item link
  that starts with `//` or `/\` linked off the site, but the site-relative
  check accepted it. The web form and the MCP content item tools now refuse
  it with the same error as a `javascript:` link.

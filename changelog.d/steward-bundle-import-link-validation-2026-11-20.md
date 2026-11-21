### Security

- **Course bundle import checks content item links.** The import now applies the
  same link rule as the content item form and MCP. A bundle with a content item
  link that is not http(s) or site-relative, for example a `javascript:` link, is
  refused before anything is saved, and the error names the item and the link.

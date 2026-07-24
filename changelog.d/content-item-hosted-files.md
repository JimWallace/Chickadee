### Added

- **Hosted files on course content items.** Instructors (TA+) can now upload
  files to a reference-material item — PDFs, notebooks, images, slides, small
  data — alongside its external links; an agent can attach one over MCP by
  passing `attachments:[{sourceUrl}]` to `create_content_item` /
  `update_content_item` (fetched under the existing SSRF guard: https-only, no
  private/loopback/metadata hosts, no redirects, size-capped). Files are stored
  under server-generated names, served only to enrolled students through the
  gated `GET /content-files/:itemID/:attachmentID` route (a draft item's files
  stay staff-only), deleted with their item or attachment, and carried in the
  `.chickadee` course bundle (exported under `content/`, re-hosted with fresh
  ids on import). A pre-attachment bundle still imports unchanged.

### Fixed

- **A refused upload on content item create no longer keeps the item.** The web create handler (`POST /instructor/content-items`) now checks every attached file before it saves the item, and removes the new item if a file write fails. A refused upload used to return 400 but keep the item with no attachments (#3214).

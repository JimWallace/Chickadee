### Fixed

- **A refused attachment on MCP `create_content_item` no longer keeps the item.** The tool now fetches and checks every attachment before it saves the item, and removes the new item if a file write fails after the checks. The cheap checks (the https rule and the file type from the URL) run on every attachment before the first fetch. A refused attachment used to return an error but keep the item with no attachments. `update_content_item` still keeps its edit when an attachment is refused, but it now writes no file until every attachment is fetched and checked.

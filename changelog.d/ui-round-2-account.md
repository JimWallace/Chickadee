### Changed

- **The account page leads with identity and courses, and its "Available
  courses" section always says something.** Order is now Account info → My
  courses → Available courses → Your data, with an identity circle carrying
  initials (there is no SSO photo — no claim in play releases one). The
  available-courses section previously carried a guard that reads as "hide when
  empty" but rendered a header-only table with no rows; it now renders either
  rows with a Join action or a line saying there is nothing to join. The
  data-export prose is unchanged and stays on the page — it is compliance text,
  not chrome.
- **Fixed: empty-list states on the account page never rendered.** LeafKit has
  no property resolution for `.isEmpty` on an array — the path resolves to nil,
  so `#if(rows.isEmpty)` is always false and `#if(!rows.isEmpty)` always true.
  Emptiness is decided in Swift now. The same idiom appears in 23 other
  templates and wants its own pass.

### Fixed

- **Admin page rendered raw HTML comment text** (regression in v0.4.415).  The `chickadee-ui.js` load comment in `base.leaf` contained `#import("content")` in its body; Leaf evaluated that as a live directive, injected the page HTML mid-comment, and the first `-->` in that content closed the comment early — leaving the remaining comment text visible on the page and duplicating the courses table.  Reworded the comment to avoid the `#` directive syntax.

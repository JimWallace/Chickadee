### Changed

- **The student pages, leaderboards and submission views render with Elementary.** The dashboard, account, submission result, GitHub submit and feedback pages, the leaderboard and its projector view, the runner detail page, the instructor submissions page, a student's course submissions and CSV enrolment are now type-checked Swift views. The leaderboard and projector polls render the same views as their pages and still answer 304 when nothing changed. Each port was compared with its Leaf output, including the spaces between inline elements, and the markup is the same apart from escaping and some whitespace that the page layout does not show. The Leaf templates for these pages and their partials are removed, except `account.leaf`, which stays unserved as the plain student page exemplar.

### Fixed

- **The projector view's tournament headings no longer skip a level.** The round labels in present mode are `h2` under the page's `h1`, not `h3`. They look the same.

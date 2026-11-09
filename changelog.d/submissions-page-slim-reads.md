### Changed

- **The instructor assignment submissions page builds fewer Fluent models.** At one course's scale it took about 300 ms, of which 31 ms was the database; the rest was turning 5,100 rows into models on the event loop. The grade-summary loader that feeds the browser-versus-native disagreement flag and the staff history pages now decodes plain rows through SQLKit; the metric cards read plain dates; the latest-submission and student rows read only the columns the page shows; and the roster reads only student ids.

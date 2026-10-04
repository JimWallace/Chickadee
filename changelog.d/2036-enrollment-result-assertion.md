### Changed

- **An enrollment render assertion can fail again (#2036).**
  `bulkEnrollCSV_enrollsMatchedUsers` checked the CSV result page with a
  disjunction that held `html.contains("2")`, which almost any page
  satisfies. It now reads each count from its own row of the page: 2
  enrolled, 1 pre-enrolled, 0 already enrolled and 0 rejected.

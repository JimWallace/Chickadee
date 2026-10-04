### Changed

- **Page tests share one `getHTML` and one `loginAsAdmin` helper (#1951).**
  Thirty APITests suites carried a private copy of "GET a page and return
  its HTML", of an admin sign-in, or of both. The new
  `Tests/APITests/TestPageHelpers.swift` holds one of each, and the private
  copies are gone. `getHTML` expects `200 OK` unless told otherwise and
  records a failure at the caller's line.

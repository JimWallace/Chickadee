### Fixed

- **Deleting a course section no longer fails with "Session refreshed".** The delete button builds its form in JavaScript, and that form had no CSRF token, so the server refused the request with a 403. The form now carries the `_csrf` field.

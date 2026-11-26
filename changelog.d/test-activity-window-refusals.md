### Changed

- **Test the live-session window refusals.** A new test in `ActivityEditPageTests` posts the instructor window form with a time the server cannot read, and with a window that closes before it opens. It checks that each gets an error and that the stored window stays the same.

### Changed

- **Test the lecture notebook link in course bundle import.** `CourseBundleRoundTripTests` now exports a course with a lecture notebook, imports it, and checks that the imported item points at the imported setup and not at the source setup. A second test checks that an item whose lecture setup is not in the bundle imports as an ordinary item.

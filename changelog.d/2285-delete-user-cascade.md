### Changed

- **Deleting a user leaves enrollments to the foreign key.** `deleteUser` deleted the user's enrollments by hand, although `course_enrollments.user_id` cascades on both backends and the handler's own comment says that only columns without a foreign key are cleared there. The hand delete is gone. A new test checks that the enrollments still go. (#2285)

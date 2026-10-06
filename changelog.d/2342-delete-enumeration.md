### Security

- **The MCP deletes no longer reveal rows in another course.** `delete_content_item` and `delete_course_section` answered an unknown id with `removed: false` but an existing row in a course the account is not enrolled in with "not enrolled", so an agent could tell which ids exist elsewhere. Both now answer that row as if it did not exist, and leave it in place, as their comments already claimed. A course the account can see still refuses a role that is too low. (#2342)

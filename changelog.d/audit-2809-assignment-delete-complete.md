### Fixed

- **Assignment delete removes all student data for the assignment (#2809).** Deleting an assignment now also removes its submission files, after the transaction commits. It also removes the class coverage runs, item coverage and class-goal data of its setup. These rows name students and have no foreign key, so they stayed behind before. The course purge already removed them. Composite and dataset-deal rows are now deleted explicitly too, as the course purge does, not only by the cascade. Both deletes now share one helper, `SetupRowDeletion`, so their table lists cannot drift apart.

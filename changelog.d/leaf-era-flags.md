### Changed

- **The view contexts no longer carry flags that repeat another field.** `hasAvatar`, `hasSpends`, `canRefund`, `hasClassGoals`, `AvatarPresentation.isLabelled` and five BrightSpace panel flags existed only because Leaf could not test an optional, an empty list or a compound condition. The views now read the field itself. An offline runner row uses the shared `.row-muted` class in place of `.runner-row-offline`. The pages render the same, except that an offline runner row is slightly less faded.

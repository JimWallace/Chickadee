### Changed

- **The layering baseline is empty (#2143).** The last seven symbols that shared code named in route files moved below the routes: `waterlooDateTimeFormatter` to `Utilities/`, the two deadline-override functions into `AssignmentDeadlineService`, `AchievementBadge` and `BadgeContext` into `AchievementBadgeEvaluation`, and `AssignmentSlugHelpers.swift` to `Helpers/`, where the slug rule now lives as `assignmentSlug(fromTitle:)` with `VanityURLRoutes.slugify` forwarding to it. `scripts/check-layering.sh` now fails on any upward call. No behaviour change.

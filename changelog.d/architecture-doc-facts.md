### Changed

- **The architecture doc and two comments name what exists.** The database section describes `DATABASE_BACKEND` and the per-backend variables the code reads, not a `DATABASE_URL` it never did; its non-additive-migration example is `CreateResultCollections`, since the other was folded away; the FK migration and the admin user deletion cite the operations doc's "User-row foreign-key cascade" heading by its real name; and the FK migration says `users`, not `api_users` (#1807).

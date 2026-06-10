### Changed

- **Achievements unification (C2): one "Achievements" table.** The three separate
  editor cards (Class Goals, Badges, Built-in Awards) are replaced by a single
  "Achievements" table at the bottom of the assignment edit page (after the Test
  Suite). Each achievement — class goals, individual badges, and the built-in
  awards — is a first-class editable row (Name / Kind / Summary / Edit / Remove);
  a row is edited in a modal whose fields adapt to the chosen kind. Driven by the
  unified `GET`/`PUT /achievements`. No custom icons.

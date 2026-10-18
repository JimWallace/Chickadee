### Added

- **The award ledger.** A student's own result page and dashboard now store each individual badge they show in a new `achievement_awards` table, once per assignment, and a regrade does not take a stored badge back (docs/achievement-rewards.md, S1). Staff views store nothing. The rows go with the account, the course and the assignment, and the account export carries them. Nothing a student sees changes yet: the trophy case and the one toast will read the ledger.

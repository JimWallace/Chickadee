### Fixed

- **The PostgreSQL major upgrade no longer rolls back on an owner-default grant.** The verify step compared the raw ACL of each table, schema and database. A table with explicit grants equal to the owner defaults restores with no explicit grants, so the check reported a difference and rolled back. It now compares effective privileges. A lost or extra grant still fails the run.

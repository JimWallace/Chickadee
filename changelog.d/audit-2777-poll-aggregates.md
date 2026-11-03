### Fixed

- **Three five-second polls no longer load whole tables (#2777).** The admin Users list reads the staff ring with one query, not an IN list of every user ID. The admin runners count reads only the known runners and the three counted statuses. The staff leaderboard counts submissions per student with one `GROUP BY`. The pages show the same output.

### Fixed

- **Only a full mark reads 100%.** A grade percent was rounded, so 199 of 200 points read 100% and earned the Ace badge, perfect-score records, authored "100%" badges and class-goal credit. One rule in Core now rounds as before but never up to 100 unless every point is earned. The displayed grade and the grades CSV follow the same rule, so 199 of 200 now shows 99% (#2018).

### Fixed

- **The mutation sweep's headline counted phantom mutants as survivors.** The
  first successful sweep reported "122 killed, 87 survived ... plus 64 phantom
  mutant(s) filtered out" — but the 87 already contained the 64, so the real
  figures were 23 survivors and 84%, not 58%. One shard read 37% when its true
  score was 81%. The per-shard table carried Muter's raw count while the JSON
  beside it carried the filtered one, and the aggregator scraped the table; it
  now reads the same `summary.json` the trend does, so the two cannot disagree.
  `Tools/mutation/report_test.py` pins the published numbers.

- **The sweep's trend record could never be saved.** It pushed to the default
  branch, which requires a pull request and four status checks — rules a bot
  committing a generated file cannot satisfy. `continue-on-error` then hid the
  refusal, so a series that could never accumulate looked exactly like a series
  with nothing in it yet. Records go to a `mutation-reports` branch, and a
  failure to persist is announced in the run summary.

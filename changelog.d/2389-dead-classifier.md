### Removed

- **The unused upload classifier in `suite-table.js`.** Since #1960 the server decides whether an uploaded file is a test, so the classifier decided nothing. It was a second list of script extensions that could drift. Its tests went with it. (#2389)

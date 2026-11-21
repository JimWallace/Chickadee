### Removed

- **Non-SQL fallbacks in class activities.** The Swift fallbacks for a database without SQL are gone from the class and lab coverage writes, the leaderboard submission counts and the latest-submission read of the classmate chooser. They now throw `AppError.internalFailure`.

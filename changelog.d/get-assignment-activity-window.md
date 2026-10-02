### Fixed

- **`get_assignment` reports the live-session window and the aggregation of a class activity.** `set_activity` told agents to read the current state from `get_assignment`, which carried neither `opensAt` nor `closesAt`. Both are now reported, present as null when unset, beside the kind's aggregation axis (#1753).

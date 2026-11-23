### Fixed

- **A runner's check-in writes its freshness once per minute, not once per slot.** The slots of one runner check in at about the same moment. Each read the same aged profile row and saved every column of it again. Production ran one such write per runner about every 22 s, against the 60 s debounce. Now an unchanged check-in updates only `last_seen_at`, and only when the stored value has aged, so the first slot's write lands and the others change no row. `last_registered_at` now moves only when a runner registers or changes its profile or name.

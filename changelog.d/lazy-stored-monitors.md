### Changed

- **Every sweep monitor and cache accessor on `Application` uses `lazyStored`.** Eighteen accessors in `Services/` still spelled the four-line get-or-create by hand, most with a setter nothing called. They now read like the LTI adopters, and the unused setters are gone (#1727).

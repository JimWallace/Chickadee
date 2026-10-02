### Fixed

- **A cloned course starts with enrollment closed.** The clone copied the source's enrollment mode, so a clone of an `.auto` course enrolled every user who logged in, last term's students included, before the instructor had set up the new term. The new offering now starts `.closed`, and the instructor opens enrollment when the term starts (#1780).

### Fixed

- **A notebook switch in the workbench no longer adds editor hooks.** Each switch added one more frame listener, one more 1.5 s poll and one more kernel watchdog, so the page ran its editor hooks once per switch and could send duplicate kernel-ready beacons. The listener and the poll are now bound once per page, and a new watchdog stops the previous one. (#2382)

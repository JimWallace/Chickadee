### Changed

- **The worker's subprocess header gives the reasons that still hold for owning the capture pipes.** It said the pipes were owned to stop a descriptor leak into concurrently spawned children, which the vendored subprocess library already prevents by marking every descriptor close-on-exec in the child. The header now names the two reasons that hold, bounded output capture and the explicit time limit, and cites the library call (#1791).

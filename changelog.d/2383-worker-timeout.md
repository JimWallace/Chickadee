### Fixed

- **An auto-compute timeout stops only its own worker.** When a case ran past its time limit, the timer stopped whichever eval worker was current, which could be a newer worker that was loading the solution. It now stops the worker that ran the case, and the other cases on that worker fail at once with a message that names the cause, instead of each waiting to report a timeout of its own. (#2383)

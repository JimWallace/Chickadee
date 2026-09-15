### Fixed

- **Closed three mutation survivors in the runner capability detector.** What
  this detector advertises is what the language gate matches a job against, and
  a wrong answer there fails quietly in both directions — over-advertising
  routes a job to a runner that dies at exit 127, under-advertising queues an
  assignment's jobs forever. The tests pin that a probe's exit status is read
  the right way round for both Python module imports and command existence, and
  that languages are reported in a stable order.

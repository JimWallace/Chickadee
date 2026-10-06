### Fixed

- **"Give new handle" no longer reports a database failure as an exhausted pool.** The redraw treated every failed save as a lost race and, after three tries, told staff that the course had no unused handle left. It now retries only when a classmate holds the drawn handle, and reports any other failure as an error (#2255).

### Fixed

- **A copied assignment gets its solution source.** The solution-save path writes `solution.py` (or the language's own file) into the shared directory and never into the setup zip, and every copy path rebuilt the shared directory from the zip alone, so a clone or an imported course whose expressions `import solution` failed until the next solution save. The clone and the bundle import now write the source from the copied solution (#1742).
